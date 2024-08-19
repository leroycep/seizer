const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.wayland);
const builtin = @import("builtin");
const xev = @import("xev");

pub const wayland = @import("./wayland.zig");

pub const fixed = packed struct(u32) {
    fraction: u8,
    integer: u23,
    sign: u1,
};
pub const GenericNewId = struct {
    interface: [:0]const u8,
    version: u32,
    new_id: u32,
};
pub const fd_t = enum(std.posix.fd_t) { _ };
pub fn NewId(comptime T: type) type {
    return struct {
        new_id: u32,

        pub const _WAYLAND_IS_NEW_ID = true;

        pub fn createOnClientSide(this: @This(), conn: *Conn) !*T {
            const t = try conn.allocator.create(T);
            t.* = .{ .conn = conn, .id = this.new_id };
            try conn.objects.put(conn.allocator, t.id, t.object());
            return t;
        }
    };
}

pub fn getDisplayPath(gpa: std.mem.Allocator) ![]u8 {
    const xdg_runtime_dir_path = try std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR");
    defer gpa.free(xdg_runtime_dir_path);
    const display_name = std.process.getEnvVarOwned(gpa, "WAYLAND_DISPLAY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try std.fs.path.join(gpa, &.{ xdg_runtime_dir_path, "wayland-0" }),
        else => return err,
    };
    defer gpa.free(display_name);

    return try std.fs.path.join(gpa, &.{ xdg_runtime_dir_path, display_name });
}

pub const DISPLAY_ID = 1;

pub const Header = extern struct {
    object_id: u32 align(1),
    size_and_opcode: SizeAndOpcode align(1),

    pub const SizeAndOpcode = packed struct(u32) {
        opcode: u16,
        size: u16,
    };
};

test "[]u32 from header" {
    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{
            1,
            (@as(u32, 12) << 16) | (4),
        },
        &@as([2]u32, @bitCast(Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        })),
    );
}

test "header from []u32" {
    try std.testing.expectEqualDeep(
        Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        },
        @as(Header, @bitCast([2]u32{
            1,
            (@as(u32, 12) << 16) | (4),
        })),
    );
}

pub fn readUInt(buffer: []const u32, parent_pos: *usize) !u32 {
    var pos = parent_pos.*;
    if (pos >= buffer.len) return error.EndOfStream;

    const uint: u32 = @bitCast(buffer[pos]);
    pos += 1;

    parent_pos.* = pos;
    return uint;
}

pub fn readInt(buffer: []const u32, parent_pos: *usize) !i32 {
    var pos = parent_pos.*;
    if (pos >= buffer.len) return error.EndOfStream;

    const int: i32 = @bitCast(buffer[pos]);
    pos += 1;

    parent_pos.* = pos;
    return int;
}

pub fn readString(buffer: []const u32, parent_pos: *usize) !?[:0]const u8 {
    var pos = parent_pos.*;

    const len = try readUInt(buffer, &pos);
    if (len == 0) return null;
    const wordlen = std.mem.alignForward(usize, len, @sizeOf(u32)) / @sizeOf(u32);

    if (pos + wordlen > buffer.len) return error.EndOfStream;
    const string = std.mem.sliceAsBytes(buffer[pos..])[0 .. len - 1 :0];
    pos += std.mem.alignForward(usize, len, @sizeOf(u32)) / @sizeOf(u32);

    parent_pos.* = pos;
    return string;
}

pub fn readArray(comptime T: type, buffer: []const u32, parent_pos: *usize) ![]const T {
    var pos = parent_pos.*;

    const byte_size = try readUInt(buffer, &pos);

    const array = @as([*]const T, @ptrCast(buffer[pos..].ptr))[0 .. byte_size / @sizeOf(T)];
    pos += byte_size / @sizeOf(u32);

    parent_pos.* = pos;
    return array;
}

pub fn deserializeArguments(comptime Signature: type, buffer: []const u32) !Signature {
    if (Signature == void) return {};
    var result: Signature = undefined;
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        if (field.type == fd_t) continue;
        switch (@typeInfo(field.type)) {
            .Int => |int_info| switch (int_info.signedness) {
                .signed => @field(result, field.name) = try readInt(buffer, &pos),
                .unsigned => @field(result, field.name) = try readUInt(buffer, &pos),
            },
            .Enum => |enum_info| if (@sizeOf(enum_info.tag_type) == @sizeOf(u32)) {
                @field(result, field.name) = @enumFromInt(try readInt(buffer, &pos));
            } else {
                @compileError("Unsupported type " ++ @typeName(field.type));
            },
            .Pointer => |ptr| switch (ptr.size) {
                // TODO: Better way to differentiate between string and array
                .Slice => if (ptr.child == u8 and ptr.sentinel != null) {
                    // if (ptr.sentinel) |s| @compileLog(std.fmt.comptimePrint("pointer sentinel = {}", .{@as(*const ptr.child, @ptrCast(s)).*}));
                    @field(result, field.name) = try readString(buffer, &pos) orelse return error.UnexpectedNullString;
                } else {
                    @field(result, field.name) = try readArray(ptr.child, buffer, &pos);
                },
                else => @compileError("Unsupported pointer size \"" ++ @tagName(ptr.size) ++ "\" (" ++ @typeName(field.type) ++ ")"),
            },
            .Optional => |opt| switch (@typeInfo(opt.child)) {
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => if (ptr.child == u8) {
                        @field(result, field.name) = try readString(buffer, &pos);
                    } else @compileError("Unsupported type " ++ @typeName(field.type)),
                    else => @compileError("Unsupported type " ++ @typeName(field.type)),
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            .Struct => |struct_info| switch (struct_info.layout) {
                .@"packed" => if (struct_info.backing_integer) |backing_int| {
                    switch (backing_int) {
                        u32 => {
                            @field(result, field.name) = @bitCast(try readUInt(buffer, &pos));
                        },
                        else => @compileError("unsupported backing integer for packed struct: " ++ @typeName(backing_int)),
                    }
                } else @compileError(@typeName(field.type) ++ "packed struct must have backing integer"),
                .auto => if (@hasDecl(field.type, "_WAYLAND_IS_NEW_ID") and field.type._WAYLAND_IS_NEW_ID) {
                    @field(result, field.name) = .{ .new_id = try readUInt(buffer, &pos) };
                } else {
                    @compileError("Structs are not supported in wayland protocol " ++ @typeName(field.type));
                },
                else => @compileError("Unsupported struct layout " ++ @tagName(struct_info.layout)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return result;
}

pub fn deserialize(comptime Union: type, header: Header, buffer: []const u32) !Union {
    if (std.meta.fields(Union).len == 0) std.debug.panic("Event has no tags!", .{});
    const op = try std.meta.intToEnum(std.meta.Tag(Union), header.size_and_opcode.opcode);
    switch (op) {
        inline else => |f| {
            const Payload = std.meta.TagPayload(Union, f);
            const payload = try deserializeArguments(Payload, buffer);
            return @unionInit(Union, @tagName(f), payload);
        },
    }
}

/// Returns the length of the serialized message in `u32` words.
pub fn calculateSerializedWordLen(comptime Signature: type, message: Signature) usize {
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        switch (@typeInfo(field.type)) {
            .Int => pos += 1,
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    // for size of string in bytes
                    pos += 1;

                    const str = @field(message, field.name);
                    pos += std.mem.alignForward(usize, str.len + 1, @sizeOf(u32)) / @sizeOf(u32);
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return pos;
}

pub fn maxFdCount(comptime Signature: type) usize {
    if (Signature == void) return 0;
    comptime var max_fd_count = 0;
    inline for (std.meta.fields(Signature)) |field| {
        max_fd_count = @max(max_fd_count, countFds(field.type));
    }
    return max_fd_count;
}

pub fn countFds(comptime Signature: type) usize {
    if (Signature == void) return 0;
    var count: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        if (field.type == fd_t) {
            count += 1;
        }
    }
    return count;
}

pub fn extractFds(comptime Signature: type, message: *const Signature, fds_buffer: []*const fd_t) []*const fd_t {
    if (Signature == void) return &[_]*const fd_t{};
    var i: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        if (field.type == fd_t) {
            fds_buffer[i] = &@field(message, field.name);
            i += 1;
        }
    }
    return fds_buffer[0..i];
}

/// Message must live until the iovec array is written.
pub fn serializeArguments(comptime Signature: type, buffer: []u32, message: Signature) ![]u32 {
    if (Signature == void) return buffer[0..0];
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        if (field.type == fd_t) continue;
        switch (@typeInfo(field.type)) {
            .Int => {
                if (pos >= buffer.len) return error.OutOfMemory;
                buffer[pos] = @bitCast(@field(message, field.name));
                pos += 1;
            },
            .Enum => |enum_info| if (enum_info.tag_type == u32) {
                if (pos >= buffer.len) return error.OutOfMemory;
                buffer[pos] = @intFromEnum(@field(message, field.name));
                pos += 1;
            } else {
                @compileError("Unsupported type " ++ @typeName(field.type));
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    const str = @field(message, field.name);
                    if (str.len >= std.math.maxInt(u32)) return error.StringTooLong;

                    buffer[pos] = @intCast(str.len + 1);
                    pos += 1;

                    const str_len_aligned = std.mem.alignForward(usize, str.len + 1, @sizeOf(u32));
                    const padding_len = str_len_aligned - str.len;
                    if (str_len_aligned / @sizeOf(u32) >= buffer[pos..].len) return error.OutOfMemory;
                    const buffer_bytes = std.mem.sliceAsBytes(buffer[pos..]);
                    @memcpy(buffer_bytes[0..str.len], str);
                    @memset(buffer_bytes[str.len..][0..padding_len], 0);
                    pos += str_len_aligned / @sizeOf(u32);
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            .Optional => |opt| switch (@typeInfo(opt.child)) {
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => if (ptr.child == u8) {
                        const str_opt = @field(message, field.name);

                        if (str_opt) |str| {
                            if (str.len >= std.math.maxInt(u32)) return error.StringTooLong;
                            buffer[pos] = @intCast(str.len + 1);
                            pos += 1;

                            const str_len_aligned = std.mem.alignForward(usize, str.len + 1, @sizeOf(u32));
                            const padding_len = str_len_aligned - str.len;
                            if (str_len_aligned / @sizeOf(u32) >= buffer[pos..].len) return error.OutOfMemory;
                            const buffer_bytes = std.mem.sliceAsBytes(buffer[pos..]);
                            @memcpy(buffer_bytes[0..str.len], str);
                            @memset(buffer_bytes[str.len..][0..padding_len], 0);
                            pos += str_len_aligned / @sizeOf(u32);
                        } else {
                            buffer[pos] = 0;
                            pos += 1;
                        }
                    } else @compileError("Unsupported type " ++ @typeName(field.type)),
                    else => @compileError("Unsupported type " ++ @typeName(field.type)),
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            .Struct => |struct_info| switch (struct_info.layout) {
                .@"packed" => if (struct_info.backing_integer) |backing_int| {
                    switch (backing_int) {
                        u32 => {
                            if (pos >= buffer.len) return error.OutOfMemory;
                            buffer[pos] = @bitCast(@field(message, field.name));
                            pos += 1;
                        },
                        else => @compileError("unsupported backing integer for packed struct: " ++ @typeName(backing_int)),
                    }
                } else @compileError(@typeName(field.type) ++ "packed struct must have backing integer"),
                else => @compileError("Unsupported struct layout for " ++ @typeName(field.type) ++ ": " ++ @tagName(struct_info.layout)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return buffer[0..pos];
}

pub fn serialize(comptime Union: type, buffer: []u32, object_id: u32, message: Union) ![]u32 {
    const header_wordlen = @sizeOf(Header) / @sizeOf(u32);
    const header: *Header = @ptrCast(buffer[0..header_wordlen]);
    header.object_id = object_id;

    const tag = std.meta.activeTag(message);
    header.size_and_opcode.opcode = @intFromEnum(tag);

    const arguments = switch (message) {
        inline else => |payload| try serializeArguments(@TypeOf(payload), buffer[header_wordlen..], payload),
    };

    header.size_and_opcode.size = @intCast(@sizeOf(Header) + arguments.len * @sizeOf(u32));
    return buffer[0 .. header.size_and_opcode.size / @sizeOf(u32)];
}

test "deserialize Registry.Event.Global" {
    const words = [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    const parsed = try deserializeArguments(wayland.wl_registry.Event.Global, &words);
    try std.testing.expectEqualDeep(wayland.wl_registry.Event.Global{
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    }, parsed);
}

test "deserialize Registry.Event" {
    const header = Header{
        .object_id = 123,
        .size_and_opcode = .{
            .size = 28,
            .opcode = @intFromEnum(wayland.Registry.Event.Tag.global),
        },
    };
    const words = [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    const parsed = try deserialize(wayland.Registry.Event, header, &words);
    try std.testing.expectEqualDeep(
        wayland.Registry.Event{
            .global = .{
                .name = 1,
                .interface = "wl_shm",
                .version = 3,
            },
        },
        parsed,
    );

    const header2 = Header{
        .object_id = 1,
        .size_and_opcode = .{
            .size = 14 * @sizeOf(u32),
            .opcode = @intFromEnum(wayland.Display.Event.Tag.@"error"),
        },
    };
    const words2 = [_]u32{
        1,
        15,
        40,
        @bitCast(@as([4]u8, "inva".*)),
        @bitCast(@as([4]u8, "lid ".*)),
        @bitCast(@as([4]u8, "argu".*)),
        @bitCast(@as([4]u8, "ment".*)),
        @bitCast(@as([4]u8, "s to".*)),
        @bitCast(@as([4]u8, " wl_".*)),
        @bitCast(@as([4]u8, "regi".*)),
        @bitCast(@as([4]u8, "stry".*)),
        @bitCast(@as([4]u8, "@2.b".*)),
        @bitCast(@as([4]u8, "ind\x00".*)),
    };
    const parsed2 = try deserialize(wayland.Display.Event, header2, &words2);
    try std.testing.expectEqualDeep(
        wayland.Display.Event{
            .@"error" = .{
                .object_id = 1,
                .code = 15,
                .message = "invalid arguments to wl_registry@2.bind",
            },
        },
        parsed2,
    );
}

test "serialize Registry.Event.Global" {
    const message = wayland.Registry.Event.Global{
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    };
    var buffer: [5]u32 = undefined;
    const serialized = try serializeArguments(wayland.Registry.Event.Global, &buffer, message);

    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{
            1,
            7,
            @bitCast(@as([4]u8, "wl_s".*)),
            @bitCast(@as([4]u8, "hm\x00\x00".*)),
            3,
        },
        serialized,
    );
}

pub const IdPool = struct {
    next_id: u32 = 2,
    free_ids: std.BoundedArray(u32, 1024) = .{},

    pub fn create(this: *@This()) u32 {
        if (this.free_ids.popOrNull()) |id| {
            return id;
        }

        defer this.next_id += 1;
        return this.next_id;
    }

    pub fn destroy(this: *@This(), id: u32) void {
        for (this.free_ids.slice()) |existing_id| {
            if (existing_id == id) return;
        }
        this.free_ids.append(id) catch {};
    }
};

const SCM = struct {
    const RIGHTS = 0x01;
};

fn cmsg(comptime T: type) type {
    const raw_struct_size = @sizeOf(c_ulong) + @sizeOf(c_int) + @sizeOf(c_int) + @sizeOf(T);
    const padded_struct_size = std.mem.alignForward(usize, @sizeOf(c_ulong) + @sizeOf(c_int) + @sizeOf(c_int) + @sizeOf(T), @alignOf(c_long));
    const padding_size = padded_struct_size - raw_struct_size;
    return extern struct {
        len: c_ulong = raw_struct_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
}

const cmsg_header_t = extern struct {
    len: c_ulong,
    level: c_int,
    type: c_int,

    // Calculate the size of the message if padding is included
    pub fn size(cmsg_header: cmsg_header_t) usize {
        return std.mem.alignForward(usize, cmsg_header.len, @alignOf(c_long));
    }
};

pub const Object = struct {
    interface: *const Interface,
    pointer: ?*anyopaque,

    pub const Interface = struct {
        name: [:0]const u8,
        version: u32,
        /// Called when the compositor sends the `delete_id` event
        delete: *const fn (Object) void,
        /// Called when message is received for this id
        event_received: *const fn (Object, header: Header, body: []const u32) void,

        pub fn fromStruct(comptime T: type, comptime typed: struct {
            name: [:0]const u8,
            version: u32,
            delete: *const fn (*T) void,
            event_received: *const fn (*T, header: Header, body: []const u32) void,
        }) Interface {
            const generic = struct {
                pub fn delete(obj: Object) void {
                    const t: *T = @ptrCast(@alignCast(obj.pointer));
                    typed.delete(t);
                }

                pub fn event_received(obj: Object, header: Header, body: []const u32) void {
                    const t: *T = @ptrCast(@alignCast(obj.pointer));
                    typed.event_received(t, header, body);
                }
            };
            return Interface{
                .name = typed.name,
                .version = typed.version,
                .delete = &generic.delete,
                .event_received = &generic.event_received,
            };
        }
    };
};

pub const Conn = struct {
    allocator: std.mem.Allocator,

    id_pool: IdPool,
    objects: std.AutoHashMapUnmanaged(u32, Object),

    /// Store a buffer to avoid allocating a serialization buffer every time `send` is called.
    send_buffer: []u32,

    recv_completion: xev.Completion,

    recv_msghdr: std.posix.msghdr,
    recv_iov: [1]std.posix.iovec,

    /// A buffer to read data into. Anything in `send_buffer.items` are bytes that have already been read.
    /// The capacity slice is used as a destination for `read` calls.
    ///
    /// Whenever possible, this buffer should be empty. All received messages that are complete should be
    /// dispatched and removed from this buffer. The only time it should have data in it is when a message
    /// has only been partially received.
    recv_buffer: std.ArrayListUnmanaged(u8),
    control_recv_buffer: std.ArrayListUnmanaged(u8),

    /// Temporarily stores file descriptors until the corresponding message is deserialized
    recv_fd_queue: std.ArrayListUnmanaged(std.posix.fd_t),

    socket: std.posix.socket_t,

    pub fn connect(conn: *Conn, loop: *xev.Loop, alloc: std.mem.Allocator, display_path: []const u8) !void {
        const send_buffer = try alloc.alloc(u32, 1024);
        errdefer alloc.free(send_buffer);

        var recv_buffer = try std.ArrayListUnmanaged(u8).initCapacity(alloc, 1024);
        errdefer recv_buffer.deinit(alloc);

        var control_recv_buffer = try std.ArrayListUnmanaged(u8).initCapacity(alloc, 1024);
        errdefer control_recv_buffer.deinit(alloc);

        const stream = try std.net.connectUnixSocket(display_path);
        errdefer stream.close();

        conn.* = .{
            .allocator = alloc,

            .id_pool = .{},
            .objects = .{},
            .send_buffer = send_buffer,

            .recv_iov = .{.{
                .base = recv_buffer.unusedCapacitySlice().ptr,
                .len = recv_buffer.unusedCapacitySlice().len,
            }},

            .recv_msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = &conn.recv_iov,
                .iovlen = conn.recv_iov.len,
                .control = control_recv_buffer.items.ptr,
                .controllen = @intCast(control_recv_buffer.items.len),
                .flags = 0,
            },

            .recv_completion = .{
                .op = .{ .recvmsg = .{
                    .fd = stream.handle,
                    .msghdr = &conn.recv_msghdr,
                } },
                .callback = recvMsgCallback,
            },
            .recv_buffer = recv_buffer,
            .control_recv_buffer = control_recv_buffer,
            .recv_fd_queue = .{},

            .socket = stream.handle,
        };

        loop.add(&conn.recv_completion);
    }

    pub fn deinit(conn: *Conn) void {
        var obj_iter = conn.objects.valueIterator();
        while (obj_iter.next()) |obj| {
            obj.interface.delete(obj.*);
        }
        conn.objects.deinit(conn.allocator);
        conn.allocator.free(conn.send_buffer);

        conn.recv_buffer.deinit(conn.allocator);
        conn.control_recv_buffer.deinit(conn.allocator);
        conn.recv_fd_queue.deinit(conn.allocator);

        std.posix.close(conn.socket);
    }

    pub fn sync(conn: *Conn) !*wayland.wl_callback {
        const object = try conn.createObject(wayland.wl_callback);
        try conn.send(wayland.wl_display.Request, DISPLAY_ID, .{ .sync = .{ .callback = object.id } });
        return object;
    }

    pub fn getRegistry(conn: *Conn) !*wayland.wl_registry {
        const object = try conn.createObject(wayland.wl_registry);
        try conn.send(wayland.wl_display.Request, DISPLAY_ID, .{ .get_registry = .{ .registry = object.id } });
        return object;
    }

    pub fn createObject(conn: *Conn, comptime T: type) !*T {
        const object = try conn.allocator.create(T);
        object.* = .{
            .conn = conn,
            .id = conn.id_pool.create(),
        };
        try conn.objects.put(conn.allocator, object.id, object.object());
        return object;
    }

    pub fn dispatchUntilSync(conn: *Conn, loop: *xev.Loop) !void {
        const x = struct {
            fn sync_callback_set_bool_to_false(registry: *wayland.wl_callback, userdata: ?*anyopaque, event: wayland.wl_callback.Event) void {
                _ = registry;
                _ = event;
                const bool_ptr: *bool = @ptrCast(@alignCast(userdata));
                bool_ptr.* = true;
            }
        };

        var sync_received = false;

        const sync_callback = try conn.sync();
        sync_callback.on_event = &x.sync_callback_set_bool_to_false;
        sync_callback.userdata = &sync_received;

        while (!sync_received) {
            try loop.run(.once);
        }
    }

    pub fn dispatchMessage(conn: *Conn, header: Header, body: []const u32) !void {
        if (conn.objects.get(header.object_id)) |object| {
            object.interface.event_received(object, header, body);
        } else if (header.object_id == DISPLAY_ID) {
            const event = try deserialize(wayland.wl_display.Event, header, body);
            switch (event) {
                .@"error" => |e| {
                    log.err("{}: {} {?s}", .{ e.object_id, e.code, e.message });
                },
                .delete_id => |d| {
                    if (conn.objects.fetchRemove(d.id)) |kv| {
                        kv.value.interface.delete(kv.value);
                        conn.id_pool.destroy(d.id);
                    }
                },
            }
        } else {
            log.warn("Unknown object id = {}", .{header.object_id});
        }
    }

    pub fn send(conn: *Conn, comptime Signature: type, id: u32, message: Signature) !void {
        const msg = while (true) {
            const msg = serialize(
                Signature,
                conn.send_buffer,
                id,
                message,
            ) catch |e| switch (e) {
                error.OutOfMemory => {
                    conn.send_buffer = try conn.allocator.realloc(conn.send_buffer, conn.send_buffer.len * 2);
                    continue;
                },
                else => return e,
            };

            break msg;
        };
        const msg_bytes = std.mem.sliceAsBytes(msg);
        const msg_iov = [_]std.posix.iovec_const{
            .{
                .base = msg_bytes.ptr,
                .len = msg_bytes.len,
            },
        };

        var fds_buffer: [maxFdCount(Signature)]*const fd_t = undefined;
        const fds = switch (message) {
            inline else => |*payload| extractFds(@TypeOf(payload.*), payload, &fds_buffer),
        };
        var ctrl_msgs_buffer: [fds_buffer.len]cmsg(std.posix.fd_t) = undefined;
        const ctrl_msgs = ctrl_msgs_buffer[0..fds.len];
        for (fds, 0..) |fdp, i| {
            ctrl_msgs[i] = .{
                .level = std.posix.SOL.SOCKET,
                .type = SCM.RIGHTS,
                .data = @intFromEnum(fdp.*),
            };
        }
        const ctrl_msgs_bytes = std.mem.sliceAsBytes(ctrl_msgs);
        const socket_msg = std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &msg_iov,
            .iovlen = msg_iov.len,
            .control = ctrl_msgs_bytes.ptr,
            .controllen = @intCast(ctrl_msgs_bytes.len),
            .flags = 0,
        };
        _ = try std.posix.sendmsg(conn.socket, &socket_msg, 0);
    }

    pub fn recvMsgCallback(userdata: ?*anyopaque, loop: *xev.Loop, completion: *xev.Completion, result: xev.Result) xev.CallbackAction {
        const conn: *Conn = @fieldParentPtr("recv_completion", completion);
        _ = userdata;
        _ = loop;

        if (result.recvmsg) |num_bytes_read| {
            conn.recv_buffer.items.len += num_bytes_read;

            // check for control messages
            const control_msg = conn.control_recv_buffer.items;
            var control_pos: usize = 0;
            while (control_pos + @sizeOf(cmsg_header_t) < control_msg.len) {
                const control_header = std.mem.bytesToValue(cmsg_header_t, control_msg[control_pos..][0..@sizeOf(cmsg_header_t)]);
                const control_data = control_msg[control_pos..][@sizeOf(cmsg_header_t) .. control_header.len - @sizeOf(cmsg_header_t)];

                if (control_header.level == std.posix.SOL.SOCKET and control_header.type == SCM.RIGHTS) {
                    const fds = std.mem.bytesAsSlice(std.posix.fd_t, control_data);
                    conn.recv_fd_queue.ensureUnusedCapacity(conn.allocator, fds.len) catch |err| {
                        std.debug.panic("Failed to receive file descriptor from socket: {}", .{err});
                    };
                    for (fds) |fd| {
                        conn.recv_fd_queue.appendAssumeCapacity(fd);
                    }
                }

                control_pos += control_header.size();
            }

            // read and dispatch received messages
            var position: usize = 0;
            while (position + @sizeOf(Header) < conn.recv_buffer.items.len) {
                const header = std.mem.bytesToValue(Header, conn.recv_buffer.items[position..][0..@sizeOf(Header)]);

                if (position + header.size_and_opcode.size >= conn.recv_buffer.items.len) {
                    break;
                }

                const message_bytes = conn.recv_buffer.items[position..][0..header.size_and_opcode.size][@sizeOf(Header)..];
                const message_words = std.mem.bytesAsSlice(u32, message_bytes);
                conn.dispatchMessage(header, @alignCast(message_words)) catch |err| {
                    std.debug.panic("Failed to dispatch wayland message: {}", .{err});
                };

                position += header.size_and_opcode.size;
            }

            // move bytes remaining in the buffer to the start of the buffer.
            const remaining_byte_count = conn.recv_buffer.items.len - position;
            for (conn.recv_buffer.items[0..remaining_byte_count], conn.recv_buffer.items[position..][0..remaining_byte_count]) |*dest, src| {
                dest.* = src;
            }
            conn.recv_buffer.items.len = remaining_byte_count;

            // if there is a header in the remaining bytes (or rather, if the remaining bytes are >= @sizeOf(Header)), ensure that the recv_buffer is large enough to receive the entire message.
            if (conn.recv_buffer.items.len >= @sizeOf(Header)) {
                const header = std.mem.bytesToValue(Header, conn.recv_buffer.items[0..@sizeOf(Header)]);
                conn.recv_buffer.ensureTotalCapacity(conn.allocator, header.size_and_opcode.size) catch |err| std.debug.panic("Could not receive message from wayland compositor: {}", .{err});
            }

            // update the iovec to point to the unused capacity slice.
            const unused_slice = conn.recv_buffer.unusedCapacitySlice();
            conn.recv_iov[0] = .{
                .base = unused_slice.ptr,
                .len = unused_slice.len,
            };

            return .rearm;
        } else |err| {
            std.log.warn("Error receiving message: {}", .{err});
            return .disarm;
        }
    }
};

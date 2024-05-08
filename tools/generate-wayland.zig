const std = @import("std");
const xml = @import("xml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const xml_file_path = args[1];
    const target_version_str: ?[]const u8 = if (args.len > 2) args[2] else null;

    const target_version: ?u32 = if (target_version_str) |ver_str| try std.fmt.parseInt(u32, ver_str, 10) else null;

    const xml_file = try std.fs.cwd().openFile(xml_file_path, .{});
    defer xml_file.close();

    var document = try xml.parse(allocator, xml_file_path, xml_file.reader());
    defer document.deinit();

    const out = std.io.getStdOut();
    const writer = out.writer();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var interface_locations = std.StringHashMap([]const u8).init(gpa.allocator());
    defer interface_locations.deinit();
    try interface_locations.putNoClobber("wl_surface", "wayland.core.Surface");
    try interface_locations.putNoClobber("wl_buffer", "wayland.core.Buffer");
    try interface_locations.putNoClobber("wl_seat", "wayland.core.Seat");
    try interface_locations.putNoClobber("wl_output", "wayland.core.Output");

    var interfaces = std.ArrayList(Interface).init(gpa.allocator());
    defer interfaces.deinit();

    const protocol_name = document.root.attr(&document, "name");
    std.log.info("protocol name = {?s}", .{protocol_name});
    for (document.root.children(&document)) |child| {
        const child_element = switch (document.node(child)) {
            .element => |elem| elem,
            else => continue,
        };
        const child_tag = document.str(child_element.tag_name);

        if (std.mem.eql(u8, child_tag, "interface")) {
            var interface = Interface{
                .name = document.elem_attr(child_element, "name") orelse return error.InvalidFormat,
                .version = try std.fmt.parseInt(u32, document.elem_attr(child_element, "version") orelse return error.InvalidFormat, 10),
                .description = std.ArrayList([]const u8).init(arena.allocator()),
                .enums = std.ArrayList(Interface.Enum).init(arena.allocator()),
                .requests = std.ArrayList(Interface.Request).init(arena.allocator()),
                .events = std.ArrayList(Interface.Event).init(arena.allocator()),
            };
            for (child_element.children(&document)) |grandchild| {
                const grandchild_element = switch (document.node(grandchild)) {
                    .element => |elem| elem,
                    else => continue,
                };
                const grandchild_tag = document.str(grandchild_element.tag_name);

                if (std.mem.eql(u8, grandchild_tag, "request")) {
                    const request = try parseRequest(arena.allocator(), &document, grandchild_element);
                    try interface.requests.append(request);
                } else if (std.mem.eql(u8, grandchild_tag, "event")) {
                    const event = try parseEvent(arena.allocator(), &document, grandchild_element);
                    try interface.events.append(event);
                } else if (std.mem.eql(u8, grandchild_tag, "description")) {
                    for (grandchild_element.children(&document)) |desc_child_id| {
                        switch (document.node(desc_child_id)) {
                            .text => |t| try interface.description.append(document.str(t)),
                            else => continue,
                        }
                    }
                } else if (std.mem.eql(u8, grandchild_tag, "enum")) {
                    const entry = try Interface.Enum.parse(arena.allocator(), &document, grandchild_element);
                    try interface.enums.append(entry);
                }
            }

            try interfaces.append(interface);
        } else if (std.mem.eql(u8, child_tag, "copyright")) {
            for (child_element.children(&document)) |grandchild| {
                const grandchild_node = document.node(grandchild);
                const text = document.str(grandchild_node.text);
                var line_iter = std.mem.splitScalar(u8, text, '\n');
                while (line_iter.next()) |line| {
                    try writer.writeAll("// ");
                    try writer.writeAll(std.mem.trimLeft(u8, line, " "));
                    try writer.writeAll("\n");
                }
                try writer.writeAll("\n");
            }
        }
    }

    for (interfaces.items) |interface| {
        for (interface.description.items) |desc| {
            var line_iter = std.mem.splitScalar(u8, desc, '\n');
            while (line_iter.next()) |line| {
                try writer.writeAll("/// ");
                try writer.writeAll(std.mem.trimLeft(u8, line, " "));
                try writer.writeAll("\n");
            }
        }
        try writer.print("pub const {[name]s} = struct {{\n", .{ .name = interface.name });
        try writer.writeAll(
            \\    conn: *wayland.Conn,
            \\    id: u32,
            \\    userdata: ?*anyopaque = null,
            \\    on_event: ?*const fn(this: *@This(), userdata: ?*anyopaque, event: Event) void = null,
            \\
            \\    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
            \\
        );
        try writer.print("    .name = \"{}\",\n", .{std.zig.fmtEscapes(interface.name)});
        try writer.print("    .version = {},\n", .{if (target_version) |tv| @min(tv, interface.version) else interface.version});
        try writer.writeAll(
            \\        .delete = delete,
            \\        .event_received = event_received,
            \\    });
            \\
            \\    pub fn object(this: *@This()) wayland.Object {
            \\        return wayland.Object{
            \\            .interface = &INTERFACE,
            \\            .pointer = this,
            \\        };
            \\    }
            \\
            \\    /// This should only be called when the wayland display sends the `delete_id` event
            \\    pub fn delete(this: *@This()) void {
            \\        this.conn.id_pool.destroy(this.id);
            \\        this.conn.allocator.destroy(this);
            \\    }
            \\
            \\    /// This should only be called when the wayland display receives an event for this Object
            \\    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
            \\        if (this.on_event) |on_event| {
            \\            const event = wayland.deserialize(Event, header, body) catch |e| {
            \\                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
            \\                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
            \\                } else |_| {
            \\                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
            \\                }
            \\                return;
            \\            };
            \\            on_event(this, this.userdata, event);
            \\        }
            \\    }
            \\
        );

        // protocol defined enums
        for (interface.enums.items) |e| {
            try writer.writeAll("    pub const ");

            if (e.bitfield) {
                var bits = std.bit_set.IntegerBitSet(32).initEmpty();
                for (e.entries.items) |entry| {
                    if (target_version != null and target_version.? < entry.since) continue;
                    if (entry.value == 0) continue;
                    const bit_index = std.math.log2(entry.value);
                    if (bits.isSet(bit_index)) return error.DuplicateBitField;
                    bits.set(bit_index);
                }

                try writer.writeByte(std.ascii.toUpper(e.name[0]));
                try writer.writeAll(e.name[1..]);
                try writer.writeAll(" = packed struct(u32) {\n");

                var bit_iter = bits.iterator(.{});
                var prev_index: usize = 0;
                var padding_number: usize = 1;
                while (bit_iter.next()) |bit_index| {
                    if (bit_index - prev_index > 1) {
                        try writer.print("        padding_{}: u{} = 0,\n", .{ padding_number, bit_index - prev_index });
                        padding_number += 1;
                    }
                    for (e.entries.items) |entry| {
                        if (target_version != null and target_version.? < entry.since) continue;
                        if (entry.value == 0) continue;
                        const value_bit_index = std.math.log2(entry.value);
                        if (value_bit_index != bit_index) continue;
                        if (entry.summary) |summary| {
                            try writer.print("        /// {s}\n", .{summary});
                        }
                        try writer.print("        {[name]s}: bool,\n", .{ .name = entry.name });
                    }

                    prev_index = bit_index;
                }
                if (prev_index != 31) {
                    try writer.print("        padding_{}: u{} = 0,\n", .{ padding_number, 31 - prev_index });
                }
                try writer.writeAll("    };\n\n");

                continue;
            }

            try writer.writeByte(std.ascii.toUpper(e.name[0]));
            try writer.writeAll(e.name[1..]);
            try writer.writeAll(" = enum(u32) {\n");
            for (e.entries.items) |entry| {
                if (target_version != null and target_version.? < entry.since) continue;
                if (entry.summary) |summary| {
                    var line_iter = std.mem.splitScalar(u8, summary, '\n');
                    while (line_iter.next()) |line| {
                        try writer.print("        /// {s}\n", .{line});
                    }
                }
                try writer.print("        {[name]s} = {[value]},\n", .{ .name = entry.name, .value = entry.value });
            }
            try writer.writeAll("    };\n\n");
        }

        // Requests enum
        try writer.writeAll("    pub const Request = union(enum) {\n");
        for (interface.requests.items) |req| {
            if (target_version != null and target_version.? < req.since) continue;

            try writer.print("        {[name]s}: struct {{\n", .{ .name = req.name });
            for (req.args.items) |arg| {
                try writer.print("            {[name]s}: ", .{ .name = arg.name });
                try arg.type.writeWireFormat(writer);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    };\n\n");

        // write out request functions
        for (interface.requests.items) |req| {
            if (target_version != null and target_version.? < req.since) continue;

            for (req.description.items) |desc| {
                var line_iter = std.mem.splitScalar(u8, desc, '\n');
                while (line_iter.next()) |line| {
                    try writer.writeAll("    /// ");
                    try writer.writeAll(std.mem.trimLeft(u8, line, " "));
                    try writer.writeAll("\n");
                }
            }

            var newid_index: ?usize = null;
            for (req.args.items, 0..) |arg, i| {
                if (arg.type.kind == .new_id) {
                    newid_index = i;
                    break;
                }
            }

            try writer.print("    pub fn {[name]s}(\n", .{ .name = req.name });
            try writer.writeAll("        this: @This(),\n");
            for (req.args.items, 0..) |arg, i| {
                if (newid_index != null and newid_index == i) continue;
                try writer.print("        {[name]s}: ", .{ .name = arg.name });
                try arg.type.writeType(writer, &interface_locations, "*");
                try writer.writeAll(",\n");
            }
            if (newid_index) |index| {
                try writer.writeAll("    ) !");
                try req.args.items[index].type.writeType(writer, &interface_locations, "*");
                try writer.writeAll(" {\n");

                try writer.writeAll("const new_object = try this.conn.createObject(");
                try req.args.items[index].type.writeType(writer, &interface_locations, "");
                try writer.writeAll(");\n");
            } else {
                try writer.print("    ) !void {{\n", .{});
            }
            try writer.print(
                \\try this.conn.send(
                \\    Request,
                \\    this.id,
                \\    .{{ .{s} = .{{
                \\
            , .{req.name});

            if (newid_index) |index| {
                try writer.print(
                    \\        .{s} = new_object.id,
                    \\
                , .{req.args.items[index].name});
            }
            for (req.args.items, 0..) |arg, i| {
                if (newid_index != null and newid_index == i) continue;
                if (arg.type.kind == .object) {
                    try writer.print("        .{[name]s} = {[name]s}.id,\n", .{ .name = arg.name });
                } else {
                    try writer.print("        .{[name]s} = {[name]s},\n", .{ .name = arg.name });
                }
            }
            try writer.writeAll(
                \\    } },
                \\);
                \\
            );
            if (newid_index) |_| {
                try writer.writeAll(
                    \\return new_object;
                    \\
                );
            }

            try writer.writeAll("    }\n\n");
        }

        // print out Events union
        try writer.writeAll("    pub const Event = union(enum) {\n");
        for (interface.events.items) |event| {
            if (target_version != null and target_version.? < event.since) continue;
            for (event.description.items) |desc| {
                var line_iter = std.mem.splitScalar(u8, desc, '\n');
                while (line_iter.next()) |line| {
                    try writer.writeAll("        /// ");
                    try writer.writeAll(std.mem.trimLeft(u8, line, " "));
                    try writer.writeAll("\n");
                }
            }
            if (event.args.items.len > 0) {
                try writer.print("        {[name]s}: struct {{\n", .{ .name = event.name });
                for (event.args.items) |arg| {
                    try writer.print("            {[name]s}: ", .{ .name = arg.name });
                    if (arg.type.kind == .new_id) {
                        try writer.writeAll("wayland.NewId(");
                        try arg.type.writeType(writer, &interface_locations, "");
                        try writer.writeAll(")");
                    } else {
                        try arg.type.writeType(writer, &interface_locations, "");
                    }
                    try writer.writeAll(",\n");
                }
                try writer.writeAll("        },\n\n");
            } else {
                try writer.print("        {[name]s},\n", .{ .name = event.name });
            }
        }
        try writer.writeAll("    };\n\n");

        try writer.print("}};\n\n", .{});
    }

    try writer.writeAll(
        \\const wayland = @import("./main.zig");
        \\const std = @import("std");
        \\
    );
}

pub fn parseRequest(gpa: std.mem.Allocator, document: *const xml.Document, element: xml.Element) !Interface.Request {
    const name = document.elem_attr(element, "name") orelse return error.InvalidFormat;

    const since_str = document.elem_attr(element, "since");
    const since = if (since_str) |s| try std.fmt.parseInt(u32, s, 10) else 0;

    var descriptions = std.ArrayList([]const u8).init(gpa);
    errdefer descriptions.deinit();

    var args = std.ArrayList(Interface.Arg).init(gpa);
    errdefer args.deinit();
    for (element.children(document)) |child_id| {
        const child_element = switch (document.node(child_id)) {
            .element => |e| e,
            else => continue,
        };
        if (std.mem.eql(u8, document.str(child_element.tag_name), "arg")) {
            try args.append(try Interface.Arg.parse(document, child_element));
        } else if (std.mem.eql(u8, document.str(child_element.tag_name), "description")) {
            for (child_element.children(document)) |desc_child_id| {
                switch (document.node(desc_child_id)) {
                    .text => |t| try descriptions.append(document.str(t)),
                    else => continue,
                }
            }
        }
    }

    return Interface.Request{
        .name = name,
        .description = descriptions,
        .args = args,
        .since = since,
    };
}

pub const Type = struct {
    kind: Kind,
    interface: ?[]const u8,
    enum_str: ?[]const u8,

    pub const Kind = enum {
        uint,
        int,
        fixed,
        new_id,
        object,
        fd,
        string,
        array,
    };

    pub fn writeWireFormat(
        this: @This(),
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => if (this.enum_str) |s| {
                try writer.writeByte(std.ascii.toUpper(s[0]));
                try writer.writeAll(s[1..]);
            } else {
                try writer.writeAll("u32");
            },
            .int => try writer.writeAll("i32"),
            .fixed => try writer.writeAll("wayland.fixed"),
            .new_id => try writer.writeAll("u32"),
            .object => try writer.writeAll("u32"),
            .fd => try writer.writeAll("wayland.fd_t"),
            .string => try writer.writeAll("?[:0]const u8"),
            .array => try writer.writeAll("[]const u8"),
        }
    }

    pub fn writeType(
        this: @This(),
        writer: anytype,
        type_locations: *const std.StringHashMap([]const u8),
        pointer_str: []const u8,
    ) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => if (this.enum_str) |s| {
                try writer.writeByte(std.ascii.toUpper(s[0]));
                try writer.writeAll(s[1..]);
            } else {
                try writer.writeAll("u32");
            },
            .int => try writer.writeAll("i32"),
            .fixed => try writer.writeAll("wayland.fixed"),
            .new_id => if (type_locations.get(this.interface orelse "wayland.GenericNewId")) |location| {
                try writer.print("{s}{s}", .{ pointer_str, location });
            } else {
                try writer.print("{s}{s}", .{ pointer_str, this.interface orelse "wayland.GenericNewId" });
            },
            .object => if (type_locations.get(this.interface orelse "")) |location| {
                try writer.print("{s}{?s}", .{ pointer_str, location });
            } else {
                try writer.print("{s}{?s}", .{ pointer_str, this.interface });
            },
            .fd => try writer.writeAll("wayland.fd_t"),
            .string => try writer.writeAll("?[:0]const u8"),
            .array => try writer.writeAll("[]const u8"),
        }
    }
};

const Interface = struct {
    name: []const u8,
    version: u32,
    description: std.ArrayList([]const u8),
    enums: std.ArrayList(Enum),
    requests: std.ArrayList(Request),
    events: std.ArrayList(Event),

    const Request = struct {
        name: []const u8,
        description: std.ArrayList([]const u8),
        args: std.ArrayList(Arg),
        since: u32,
    };

    const Event = struct {
        name: []const u8,
        description: std.ArrayList([]const u8),
        args: std.ArrayList(Arg),
        since: u32,
    };

    pub const Arg = struct {
        name: []const u8,
        type: Type,

        pub fn parse(document: *const xml.Document, element: xml.Element) !Arg {
            const arg_name = document.elem_attr(element, "name") orelse return error.InvalidFormat;
            const arg_type_str = document.elem_attr(element, "type") orelse return error.InvalidFormat;
            errdefer std.log.warn("unknown type = {s}", .{arg_type_str});

            const arg_type = std.meta.stringToEnum(Type.Kind, arg_type_str) orelse return error.InvalidFormat;
            const arg_interface_str = document.elem_attr(element, "interface");
            const enum_str = document.elem_attr(element, "enum");

            return Arg{
                .name = arg_name,
                .type = .{
                    .kind = arg_type,
                    .interface = arg_interface_str,
                    .enum_str = enum_str,
                },
            };
        }
    };

    pub const Enum = struct {
        name: []const u8,
        bitfield: bool,
        entries: std.ArrayList(Entry),

        pub const Entry = struct {
            name: []const u8,
            value: u32,
            summary: ?[]const u8,
            since: u32,
        };

        pub fn parse(gpa: std.mem.Allocator, document: *const xml.Document, element: xml.Element) !Enum {
            const name = document.elem_attr(element, "name") orelse return error.InvalidFormat;
            const bitfield = blk: {
                const bool_str = document.elem_attr(element, "bitfield") orelse break :blk false;
                break :blk std.mem.eql(u8, bool_str, "true");
            };

            var entries = std.ArrayList(Entry).init(gpa);
            errdefer entries.deinit();

            for (element.children(document)) |child_id| {
                const child_element = switch (document.node(child_id)) {
                    .element => |e| e,
                    else => continue,
                };
                if (std.mem.eql(u8, document.str(child_element.tag_name), "entry")) {
                    const entry_name = document.elem_attr(child_element, "name") orelse return error.InvalidFormat;
                    const entry_value_str = document.elem_attr(child_element, "value") orelse return error.InvalidFormat;
                    const entry_value = try std.fmt.parseInt(u32, entry_value_str, 10);
                    const entry_summary = document.elem_attr(child_element, "summary");

                    const since_str = document.elem_attr(element, "since");
                    const since = if (since_str) |s| try std.fmt.parseInt(u32, s, 10) else 0;

                    try entries.append(Entry{
                        .name = entry_name,
                        .value = entry_value,
                        .summary = entry_summary,
                        .since = since,
                    });
                }
            }

            return Interface.Enum{
                .name = name,
                .bitfield = bitfield,
                .entries = entries,
            };
        }
    };
};

pub fn parseEvent(gpa: std.mem.Allocator, document: *const xml.Document, element: xml.Element) !Interface.Event {
    const name = document.elem_attr(element, "name") orelse return error.InvalidFormat;
    const since_str = document.elem_attr(element, "since");

    const since = if (since_str) |s| try std.fmt.parseInt(u32, s, 10) else 0;

    var descriptions = std.ArrayList([]const u8).init(gpa);
    errdefer descriptions.deinit();

    var args = std.ArrayList(Interface.Arg).init(gpa);
    errdefer args.deinit();
    for (element.children(document)) |child_id| {
        const child_element = switch (document.node(child_id)) {
            .element => |e| e,
            else => continue,
        };
        if (std.mem.eql(u8, document.str(child_element.tag_name), "arg")) {
            try args.append(try Interface.Arg.parse(document, child_element));
        } else if (std.mem.eql(u8, document.str(child_element.tag_name), "description")) {
            for (child_element.children(document)) |desc_child_id| {
                switch (document.node(desc_child_id)) {
                    .text => |t| try descriptions.append(document.str(t)),
                    else => continue,
                }
            }
        }
    }

    return Interface.Event{
        .name = name,
        .description = descriptions,
        .args = args,
        .since = since,
    };
}

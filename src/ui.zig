//! A simple backend agnostic UI library for zig. Provides tools to quickly layout
//! user interfaces in code and bring them to life on screen. Depends only on the
//! zig std library.

pub const store = @import("ui/store.zig");

const std = @import("std");
const geom = @import("geometry.zig");
const Vec = geom.Vec2;
const Rect = geom.Rect;

const Allocator = std.mem.Allocator;

const List = std.ArrayList;

pub const Event = enum {
    PointerMove,
    PointerPress,
    PointerRelease,
    PointerClick,
    PointerEnter,
    PointerLeave,
};

pub const EventData = struct {
    _type: Event,
    pointer: PointerData,
    current: usize,
    target: usize,
};

pub const InputData = struct {
    pointer: PointerData,
    keys: KeyData,
};

const InputInfo = struct {
    pointer_diff: geom.Vec2,
    pointer_move: bool,
    pointer_press: bool,
    pointer_release: bool,
    secondary_press: bool,
    secondary_release: bool,
    pointer_drag: bool,
};

pub const PointerData = struct {
    left: bool,
    right: bool,
    middle: bool,
    pos: Vec,
};

pub const KeyData = struct {
    up: bool,
    down: bool,
    left: bool,
    right: bool,
    accept: bool,
    reject: bool,
};

pub fn Audience(comptime T: type) type {
    return struct {
        const Callback = fn (T, EventData) void;
        const Listener = struct { handle: usize, event: Event, callback: Callback };

        list: std.ArrayList(Listener),

        pub fn init(alloc: Allocator) @This() {
            return @This(){
                .list = std.ArrayList(Listener).init(alloc),
            };
        }

        pub fn deinit(this: *@This()) void {
            this.list.deinit();
        }

        pub fn add(this: *@This(), handle: usize, event: Event, callback: Callback) !void {
            try this.list.append(.{ .handle = handle, .event = event, .callback = callback });
        }

        pub fn dispatch(this: *@This(), ctx: T, event: EventData) void {
            for (this.list.items) |listener| {
                if (event._type == listener.event and event.current == listener.handle) {
                    listener.callback(ctx, event);
                }
            }
        }
    };
}

/// Available layout algorithms
pub const Layout = union(enum) {
    /// Default layout of root - expands children to fill entire space
    Fill,
    /// Default layout. Children are positioned relative to the parent with no
    /// attempt made to prevent overlapping.
    Relative,
    /// Keep elements centered
    Center,
    /// Specify an anchor (between 0 and 1) and a margin (in screen space) for
    /// childrens bounding box
    Anchor: struct { anchor: Rect, margin: Rect },
    // Divide horizontal space equally
    HDiv,
    // Divide vertical space equally
    VDiv,
    // Stack elements horizontally
    HList: struct { left: i32 = 0 },
    // Stack elements vertically
    VList: struct { top: i32 = 0 },
    // Takes a slice of ints specifying the relative size of each column
    // Grid: []const f32,
};

/// Provide your basic types
pub fn Stage(comptime Style: type, comptime Painter: type, comptime T: type) type {
    if (!@hasDecl(Painter, "size")) @compileLog("Painter must have fn size(*Painter, Node) Vec2");
    if (!@hasDecl(Painter, "padding")) @compileLog("Painter must have fn padding(*Painter, Node) Rect");
    if (!@hasDecl(Painter, "paint")) @compileLog("Painter must have fn paint(*Painter, Node) void");
    return struct {
        modified: bool,
        inputs_last: InputData = .{
            .pointer = .{ .pos = Vec{ 0, 0 }, .left = false, .right = false, .middle = false },
            .keys = .{
                .up = false,
                .left = false,
                .right = false,
                .down = false,
                .accept = false,
                .reject = false,
            },
        },
        pointer_start_press: Vec = Vec{ 0, 0 },
        /// A monotonically increasing integer assigning new handles
        handle_count: usize,
        root_layout: Layout = .Fill,
        /// Array of all ui elements
        nodes: List(Node),
        /// Array of reorder operations to perform
        reorder_op: ?Reorder,
        painter: *Painter,

        // Reorder operations that can take significant processing time, so
        // wait until we are doing layout to begin
        const Reorder = union(enum) {
            // Insert: usize,
            Remove: usize,
            BringToFront: usize,
        };

        pub const PaintFn = fn (Node) void;
        pub const SizeFn = fn (T) Vec;

        const Self = @This();

        pub const Node = struct {
            /// Determines whether the current node and it's children are visible
            hidden: bool = false,
            /// Indicates whether the rect has a background
            style: Style,
            /// If the node prevents other nodes from recieving events
            event_filter: EventFilter = .Prevent,
            /// Whether the pointer is over the node
            pointer_over: bool = false,
            /// If the pointer is pressed over the node
            pointer_pressed: bool = false,
            /// Pointer FSM
            pointer_state: enum { Open, Hover, Press, Drag, Click } = .Open,
            /// How many descendants this node has
            children: usize = 0,
            /// A unique handle
            handle: usize = 0,
            ///
            padding: Rect = Rect{ 0, 0, 0, 0 },
            /// Minimum size of the element
            min_size: Vec = Vec{ 0, 0 },
            /// Actual size
            size: Vec = Vec{ 0, 0 },
            /// Screen space rectangle
            bounds: Rect = Rect{ 0, 0, 0, 0 },
            /// What layout function to use on children
            layout: Layout = .Relative,
            /// User specified type
            data: ?T = null,

            const EventFilter = union(enum) { Prevent, Pass, PassExcept: Event };

            pub fn anchor(_anchor: Rect, margin: Rect, style: Style) @This() {
                return @This(){
                    .layout = .{
                        .Anchor = .{
                            .anchor = _anchor,
                            .margin = margin,
                        },
                    },
                    .style = style,
                };
            }

            pub fn fill(style: Style) @This() {
                return @This(){
                    .layout = .Fill,
                    .style = style,
                };
            }

            pub fn relative(style: Style) @This() {
                return @This(){
                    .layout = .Relative,
                    .style = style,
                };
            }

            pub fn center(style: Style) @This() {
                return @This(){
                    .layout = .Center,
                    .style = style,
                };
            }

            pub fn vlist(style: Style) @This() {
                return @This(){
                    .layout = .{ .VList = .{} },
                    .style = style,
                };
            }

            pub fn hlist(style: Style) @This() {
                return @This(){
                    .layout = .{ .HList = .{} },
                    .style = style,
                };
            }

            pub fn vdiv(style: Style) @This() {
                return @This(){
                    .layout = .{ .VDiv = .{} },
                    .style = style,
                };
            }

            pub fn hdiv(style: Style) @This() {
                return @This(){
                    .layout = .{ .HDiv = .{} },
                    .style = style,
                };
            }

            pub fn eventFilter(this: @This(), value: EventFilter) @This() {
                var node = this;
                node.event_filter = value;
                return node;
            }

            pub fn hasStyle(this: @This(), value: Style) @This() {
                var node = this;
                node.style = value;
                return node;
            }

            pub fn dataValue(this: @This(), value: T) @This() {
                var node = this;
                node.data = value;
                return node;
            }

            pub fn minSize(this: @This(), value: Vec) @This() {
                var node = this;
                node.min_size = value;
                return node;
            }
        };

        pub fn init(alloc: Allocator, painter: *Painter) !@This() {
            var nodelist = try List(Node).initCapacity(alloc, 40);
            return @This(){
                .modified = true,
                .handle_count = 100,
                .nodes = nodelist,
                .reorder_op = null,
                .painter = painter,
            };
        }

        pub fn deinit(this: *@This()) void {
            this.nodes.deinit();
        }

        pub fn print_list(this: @This(), alloc: Allocator, print: fn ([]const u8) void) !void {
            const header = try std.fmt.allocPrint(
                alloc,
                "{s:^16}|{s:^16}|{s:^8}|{s:^8}",
                .{ "layout", "datatype", "children", "hidden" },
            );
            defer alloc.free(header);
            print(header);
            for (this.nodes.items) |node| {
                const typename: [*:0]const u8 = @tagName(node.layout);
                const dataname: [*:0]const u8 = if (node.data) |data| @tagName(data) else "null";
                const log = try std.fmt.allocPrint(
                    alloc,
                    "{s:<16}|{s:^16}|{:^8}|{:^8}",
                    .{ typename, dataname, node.children, node.hidden },
                );
                defer alloc.free(log);
                print(log);
            }
        }

        pub fn print_debug(this: @This(), alloc: Allocator, print: fn ([]const u8) void) void {
            var child_iter = this.get_root_iter();
            while (child_iter.next()) |childi| {
                this.print_recursive(alloc, print, childi, 0);
            }
        }

        pub fn print_recursive(this: @This(), alloc: Allocator, print: fn ([]const u8) void, index: usize, depth: usize) void {
            const node = this.nodes.items[index];
            const typename: [*:0]const u8 = @tagName(node.layout);
            const dataname: [*:0]const u8 = if (node.data) |data| @tagName(data) else "null";
            const depth_as_bits = @as(u8, 1) << @intCast(u3, depth);
            const log = std.fmt.allocPrint(
                alloc,
                "{b:>8}\t{:>16}|{s:<16}|{s:^16}|{:^8}|{:^8}",
                .{ depth_as_bits, node.handle, typename, dataname, node.children, node.hidden },
            ) catch @panic("yeah");
            defer alloc.free(log);
            print(log);
            var child_iter = this.get_child_iter(index);
            while (child_iter.next()) |childi| {
                this.print_recursive(alloc, print, childi, depth + 1);
            }
        }

        /// Create a new node under given parent. Pass null to create a top level element.
        pub fn insert(this: *@This(), parent_opt: ?usize, node: Node) !usize {
            this.modified = true;
            const handle = this.handle_count;
            this.handle_count += 1;
            var index: usize = undefined;
            var no_parent = parent_opt == null;
            if (parent_opt) |parent_handle| {
                const parent_o = this.get_index_by_handle(parent_handle);
                if (parent_o) |parent| {
                    const p = this.nodes.items[parent];
                    index = parent + p.children + 1;
                    try this.nodes.insert(index, node);
                    this.nodes.items[index].handle = handle;

                    this.nodes.items[parent].children += 1;
                    var parent_iter = this.get_parent_iter(parent);
                    while (parent_iter.next()) |ancestor| {
                        this.nodes.items[ancestor].children += 1;
                    }
                } else {
                    no_parent = true;
                }
            }
            if (no_parent) {
                try this.nodes.append(node);
                index = this.nodes.items.len - 1;
                this.nodes.items[index].handle = handle;
            }
            this.nodes.items[index].padding = this.painter.padding(node);
            const min_size = this.painter.size(node);
            this.nodes.items[index].min_size = @select(
                i32,
                this.nodes.items[index].min_size < min_size,
                min_size,
                this.nodes.items[index].min_size,
            );
            return handle;
        }

        const EventIterator = struct {
            ctx: *Self,
            current_event: Event = .PointerEnter,
            run: bool = true,
            node: Node,
            index: usize,
            inputs: InputData,
            input_info: InputInfo,
            pub fn init(ctx: *Self, index: usize, node: Node, inputs: InputData, info: InputInfo, pointer_captured: bool) ?@This() {
                var this = @This(){
                    .ctx = ctx,
                    .node = node,
                    .index = index,
                    .inputs = inputs,
                    .input_info = info,
                };
                if (geom.rect.contains(node.bounds, this.inputs.pointer.pos) and !pointer_captured) {
                    this.ctx.nodes.items[this.index].pointer_over = true;
                    this.ctx.nodes.items[this.index].pointer_pressed = this.inputs.pointer.left;
                } else {
                    this.ctx.nodes.items[this.index].pointer_over = false;
                    this.ctx.nodes.items[this.index].pointer_pressed = false;
                    if (node.pointer_over) {
                        this.current_event = .PointerLeave;
                    } else {
                        this.run = false;
                        this.ctx.nodes.items[this.index].pointer_state = .Open;
                    }
                }
                return this;
            }

            fn get_event(this: *@This(), event: Event) EventData {
                return EventData{ ._type = event, .pointer = this.inputs.pointer, .target = this.node.handle, .current = this.node.handle };
            }

            pub fn next(this: *@This()) ?EventData {
                const node = this.node;
                while (this.run) {
                    switch (this.current_event) {
                        .PointerEnter => {
                            this.current_event = .PointerMove;
                            if (!node.pointer_over) return this.get_event(.PointerEnter);
                        },
                        .PointerMove => {
                            this.current_event = .PointerPress;
                            if (this.input_info.pointer_move) return this.get_event(.PointerMove);
                        },
                        .PointerPress => {
                            this.current_event = .PointerRelease;
                            if (this.input_info.pointer_press or this.input_info.secondary_press) return this.get_event(.PointerPress);
                        },
                        .PointerRelease => {
                            this.current_event = .PointerClick;
                            if (this.input_info.pointer_release or this.input_info.secondary_release) return this.get_event(.PointerRelease);
                        },
                        .PointerClick => {
                            this.run = false;
                            const nptr = &this.ctx.nodes.items[this.index].pointer_state;
                            switch (node.pointer_state) {
                                .Open => {
                                    nptr.* = .Hover;
                                    if (this.input_info.pointer_press) nptr.* = .Press;
                                },
                                .Hover => {
                                    if (this.input_info.pointer_press) nptr.* = .Press;
                                },
                                .Press => {
                                    if (this.input_info.pointer_release) nptr.* = .Click;
                                    if (this.input_info.pointer_drag) nptr.* = .Drag;
                                },
                                .Drag => {
                                    if (this.input_info.pointer_release) nptr.* = .Hover;
                                },
                                .Click => {
                                    nptr.* = .Open;
                                    return this.get_event(.PointerClick);
                                },
                            }
                        },
                        .PointerLeave => {
                            this.run = false;
                            if (node.pointer_over) return this.get_event(.PointerLeave);
                        },
                    }
                }
                return null;
            }
        };

        const drag_threshold = 10 * 10;
        pub const UpdateIterator = struct {
            ctx: *Self,
            // Running variables
            index: usize,
            run: bool = true,
            pointer_captured: bool = false,
            bubbling: ?struct { iter: ParentIter, event: EventData } = null,
            event_iter: ?EventIterator = null,
            // Defined at beginning of loop
            inputs: InputData,
            input_info: InputInfo,

            pub fn next(this: *@This()) ?EventData {
                if (!this.run) return null;
                if (this.ctx.nodes.items.len == 0) return null;
                while (this.run) {
                    if (this.bubbling) |*bubble| {
                        while (bubble.iter.next()) |parent_index| {
                            const parent = this.ctx.nodes.items[parent_index];
                            bubble.event.current = parent.handle;
                            switch (parent.event_filter) {
                                .Pass => {},
                                .PassExcept => |except| if (except == bubble.event._type) {
                                    this.pointer_captured = true;
                                },
                                .Prevent => {
                                    this.pointer_captured = true;
                                },
                            }
                            if (this.pointer_captured) break;
                        }
                        this.bubbling = null;
                    }
                    if (this.event_iter) |*event_iter| {
                        if (event_iter.next()) |event_data| {
                            switch (event_data._type) {
                                .PointerMove, .PointerPress, .PointerRelease, .PointerClick => {
                                    if (this.ctx.nodes.items[this.index].event_filter != .Pass) {
                                        this.pointer_captured = true;
                                    } else {
                                        this.bubbling = .{
                                            .iter = this.ctx.get_parent_iter(this.index),
                                            .event = event_data,
                                        };
                                    }
                                },
                                .PointerEnter, .PointerLeave => {
                                    if (this.ctx.nodes.items[this.index].event_filter != .Pass) {
                                        this.pointer_captured = true;
                                    }
                                },
                            }
                            return event_data;
                        }
                        this.index -|= 1;
                        this.event_iter = null;
                        if (this.index == 0) {
                            this.ctx.inputs_last = this.inputs;
                            this.run = false;
                            return null;
                        }
                    }

                    const node = this.ctx.nodes.items[this.index];
                    this.event_iter = EventIterator.init(this.ctx, this.index, node, this.inputs, this.input_info, this.pointer_captured);
                }
                return null;
            }
        };

        /// Pass inputs, receive UI events
        pub fn poll(this: *@This(), inputs: InputData) UpdateIterator {
            // Collect info about state
            const pointer_diff = inputs.pointer.pos - this.inputs_last.pointer.pos;
            const pointer_move = @reduce(.Or, pointer_diff != Vec{ 0, 0 });
            const pointer_press = !this.inputs_last.pointer.left and inputs.pointer.left;
            if (pointer_press) {
                this.pointer_start_press = inputs.pointer.pos;
            }
            const pointer_release = this.inputs_last.pointer.left and !inputs.pointer.left;
            const secondary_press = !this.inputs_last.pointer.right and inputs.pointer.right;
            const secondary_release = this.inputs_last.pointer.right and !inputs.pointer.right;
            const pointer_drag = //
                inputs.pointer.left and
                pointer_move and
                geom.vec.dist_sqr(this.pointer_start_press, inputs.pointer.pos) > drag_threshold;
            var input_info = InputInfo{
                .pointer_diff = pointer_diff,
                .pointer_move = pointer_move,
                .pointer_press = pointer_press,
                .pointer_release = pointer_release,
                .secondary_press = secondary_press,
                .secondary_release = secondary_release,
                .pointer_drag = pointer_drag,
            };
            var iter = UpdateIterator{
                .ctx = this,
                .index = this.nodes.items.len -| 1,
                .inputs = inputs,
                .input_info = input_info,
            };
            return iter;
        }

        pub fn paint(this: @This()) void {
            var i: usize = 0;
            while (i < this.nodes.items.len) : (i += 1) {
                const node = this.nodes.items[i];
                if (node.hidden) {
                    i += node.children;
                    continue;
                }
                this.painter.paint(node);
            }
        }

        /// Layout
        pub fn layout(this: *@This(), screen: Rect) void {
            // Nothing to layout
            if (this.nodes.items.len == 0) return;
            // If nothing has been modified, we don't need to proceed
            if (!this.modified) return;
            // Perform reorder operation if one was queued
            if (this.reorder_op != null) {
                this.reorder();
            }

            this.run_sizing();

            if (this.root_layout == .VList) {
                this.root_layout.VList.top = 0;
            }
            if (this.root_layout == .HList) {
                this.root_layout.HList.left = 0;
            }

            // Layout top level
            var childIter = this.get_root_iter();
            const child_count = this.get_root_child_count();
            var child_num: usize = 0;
            while (childIter.next()) |childi| : (child_num += 1) {
                this.root_layout = this.run_layout(this.root_layout, screen, childi, child_num, child_count);
                // Run layout for child nodes
                this.layout_children(childi);
            }
        }

        pub fn run_sizing(this: *@This()) void {
            var i: usize = this.nodes.items.len - 1;
            while (i > 0) : (i -|= 1) {
                const node = this.nodes.items[i];
                this.nodes.items[i].size = this.compute_size(node, i);
                if (i == 0) break;
            }
        }

        pub fn compute_size(this: *@This(), node: Node, index: usize) geom.Vec2 {
            const stack_vertically = node.layout == .VList or node.layout == .VDiv;
            const stack_horizontally = node.layout == .HList or node.layout == .HDiv;
            var size = node.min_size;
            var child_iter = this.get_child_iter(index);
            var count: usize = 0;
            while (child_iter.next()) |child_index| {
                count += 1;
                const child = this.nodes.items[child_index];
                const child_total = child.size;
                // If the container is a list, stack sizes
                if (stack_vertically) {
                    size[1] += child_total[1];
                } else if (stack_horizontally) {
                    size[0] += child_total[0];
                }
                // Regardless of container type, the size should always be
                // greater than or equal to the child total
                size = @select(i32, child_total > size, child_total, size);
            }
            // Now that our child sizes are computed, add padding on top of it
            const padding = geom.Vec2{ node.padding[0] + node.padding[2], node.padding[1] + node.padding[3] };
            size += padding;
            return size;
        }

        pub fn layout_children(this: *@This(), index: usize) void {
            const node = this.nodes.items[index];
            if (node.layout == .VList) {
                this.nodes.items[index].layout.VList.top = 0;
            }
            if (node.layout == .HList) {
                this.nodes.items[index].layout.HList.left = 0;
            }
            const child_bounds = node.bounds + (node.padding * geom.Rect{ 1, 1, -1, -1 });
            var childIter = this.get_child_iter(index);
            const child_count = this.get_child_count(index);
            var child_num: usize = 0;
            while (childIter.next()) |childi| : (child_num += 1) {
                this.nodes.items[index].layout = this.run_layout(this.nodes.items[index].layout, child_bounds, childi, child_num, child_count);
                // Run layout for child nodes
                this.layout_children(childi);
            }
        }

        /// Runs the layout function and returns the new state of the layout component, if applicable
        fn run_layout(this: *@This(), which_layout: Layout, bounds: Rect, child_index: usize, child_num: usize, child_count: usize) Layout {
            const child = this.nodes.items[child_index];
            const total = child.size;
            switch (which_layout) {
                .Fill => {
                    this.nodes.items[child_index].bounds = bounds;
                    return .Fill;
                },
                .Relative => {
                    const pos = geom.rect.top_left(bounds);
                    this.nodes.items[child_index].bounds = Rect{ pos[0], pos[1], pos[0] + total[0], pos[1] + total[1] };
                    return .Relative;
                },
                .Center => {
                    const min_half = @divTrunc(total, Vec{ 2, 2 });
                    const center = @divTrunc(geom.rect.size(bounds), Vec{ 2, 2 });
                    const pos = geom.rect.top_left(bounds) + center - min_half;
                    this.nodes.items[child_index].bounds = Rect{ pos[0], pos[1], pos[0] + total[0], pos[1] + total[1] };
                    return .Center;
                },
                .Anchor => |anchor_data| {
                    const MAX = geom.vec.double(.{ 100, 100 });
                    const size_doubled = geom.vec.double((geom.rect.bottom_right(bounds) - geom.rect.top_left(bounds)));
                    const anchor = geom.rect.shift(
                        @divTrunc((MAX - (MAX - anchor_data.anchor)) * size_doubled, MAX),
                        geom.rect.top_left(bounds),
                    );
                    const margin = anchor + anchor_data.margin;
                    this.nodes.items[child_index].bounds = margin;
                    return .{ .Anchor = anchor_data };
                },
                .VList => |vlist_data| {
                    const _left = bounds[0];
                    const _top = bounds[1] + vlist_data.top;
                    const _right = bounds[2];
                    const _bottom = _top + total[1];
                    this.nodes.items[child_index].bounds = Rect{ _left, _top, _right, _bottom };
                    return .{ .VList = .{ .top = _bottom - bounds[1] } };
                },
                .HList => |hlist_data| {
                    const _left = bounds[0] + hlist_data.left;
                    const _top = bounds[1];
                    const _right = _left + total[0];
                    const _bottom = bounds[3];
                    this.nodes.items[child_index].bounds = Rect{ _left, _top, _right, _bottom };
                    return .{ .HList = .{ .left = _right - bounds[0] } };
                },
                .VDiv => {
                    const vsize = @divTrunc(geom.rect.size(bounds)[1], @intCast(i32, child_count));
                    const num = @intCast(i32, child_num);
                    this.nodes.items[child_index].bounds = Rect{ bounds[0], bounds[1] + vsize * num, bounds[2], bounds[1] + vsize * (num + 1) };
                    return .VDiv;
                },
                .HDiv => {
                    const hsize = @divTrunc(geom.rect.size(bounds)[0], @intCast(i32, child_count));
                    const num = @intCast(i32, child_num);
                    this.nodes.items[child_index].bounds = Rect{ bounds[0] + hsize * num, bounds[1], bounds[0] + hsize * (num + 1), bounds[3] };
                    return .HDiv;
                },
            }
        }

        const ChildIter = struct {
            nodes: []Node,
            index: usize,
            end: usize,
            pub fn next(this: *@This()) ?usize {
                if (this.index > this.end or this.index > this.nodes.len) return null;
                const index = this.index;
                const node = this.nodes[index];
                this.index += node.children + 1;
                return index;
            }
        };

        /// Returns an iterator over the direct childtren of given node
        pub fn get_child_iter(this: @This(), index: usize) ChildIter {
            const node = this.nodes.items[index];
            return ChildIter{
                .nodes = this.nodes.items,
                .index = index + 1,
                .end = index + node.children,
            };
        }

        /// Returns an iterator over the root's direct children
        pub fn get_root_iter(this: @This()) ChildIter {
            return ChildIter{
                .nodes = this.nodes.items,
                .index = 0,
                .end = this.nodes.items.len - 1,
            };
        }

        /// Returns a count of the direct children of the node
        pub fn get_child_count(this: @This(), index: usize) usize {
            const node = this.nodes.items[index];
            if (node.children <= 1) return node.children;
            var children: usize = 0;
            var childIter = this.get_child_iter(index);
            while (childIter.next()) |_| : (children += 1) {}
            return children;
        }

        pub fn get_root_child_count(this: @This()) usize {
            if (this.get_count() <= 1) return this.get_count();
            var children: usize = 0;
            var childIter = this.get_root_iter();
            while (childIter.next()) |_| : (children += 1) {}
            return children;
        }

        pub fn get_count(this: @This()) usize {
            return this.nodes.items.len;
        }

        pub fn get_index_by_handle(this: @This(), handle: usize) ?usize {
            for (this.nodes.items) |node, i| {
                if (node.handle == handle) return i;
            }
            return null;
        }

        pub fn get_node(this: @This(), handle: usize) ?Node {
            if (this.get_index_by_handle(handle)) |node| {
                return this.nodes.items[node];
            }
            return null;
        }

        pub fn set_slice_hidden(slice: []Node, hidden: bool) void {
            for (slice) |*node| {
                node.*.hidden = hidden;
            }
        }

        pub fn hide_node(this: *@This(), handle: usize) bool {
            if (this.get_index_by_handle(handle)) |i| {
                var rootnode = this.nodes.items[i];
                var slice = this.nodes.items[i .. i + rootnode.children];
                set_slice_hidden(slice, true);
                return true;
            }
            return false;
        }

        pub fn show_node(this: *@This(), handle: usize) bool {
            if (this.get_index_by_handle(handle)) |i| {
                var rootnode = this.nodes.items[i];
                var slice = this.nodes.items[i .. i + rootnode.children];
                set_slice_hidden(slice, false);
                return true;
            }
            return false;
        }

        pub fn toggle_hidden(this: *@This(), handle: usize) bool {
            if (this.get_index_by_handle(handle)) |i| {
                const rootnode = this.nodes.items[i];
                const hidden = !rootnode.hidden;
                var slice = this.nodes.items[i .. i + rootnode.children];
                set_slice_hidden(slice, hidden);
                return true;
            }
            return false;
        }

        /// Returns true if the node existed
        pub fn set_node(this: *@This(), node: Node) bool {
            if (this.get_index_by_handle(node.handle)) |i| {
                this.nodes.items[i] = node;
                this.modified = true;
                return true;
            }
            return false;
        }

        const ParentIter = struct {
            nodes: []Node,
            index: usize,
            child_component: usize,
            pub fn next(this: *@This()) ?usize {
                const index = this.index;
                while (true) : (this.index -|= 1) {
                    const node = this.nodes[this.index];
                    if (index != this.index and this.index + node.children >= this.child_component) {
                        // Never return with the same index as we started with
                        return this.index;
                    }
                    if (this.index == 0) return null;
                }
                return null;
            }
        };

        pub fn get_parent_iter(this: @This(), index: usize) ParentIter {
            return ParentIter{
                .nodes = this.nodes.items,
                .index = index,
                .child_component = index,
            };
        }

        /// Get the parent of given element. Returns null if the parent is the root
        pub fn get_parent(this: @This(), id: usize) ?usize {
            if (id == 0) return null;
            if (id > this.get_count()) return null; // The id is outside of bounds
            var i: usize = id - 1;
            while (true) : (i -= 1) {
                const node = this.nodes.items[i];
                // If the node's children includes the searched for id, it is a
                // parent, and our loop will end as soon as we find the first
                // one
                if (i + node.children >= id) return i;
                if (i == 0) break;
            }
            return null;
        }

        pub fn get_ancestor(this: @This(), handle: usize, ancestor_num: usize) ?Node {
            if (this.get_index_by_handle(handle)) |index| {
                var i: usize = 0;
                var parent_iter = this.get_parent_iter(index);
                while (parent_iter.next()) |parent| : (i += 1) {
                    if (i == ancestor_num) {
                        return this.nodes.items[parent];
                    }
                }
            }
            return null;
        }

        pub fn get_ancestor_id(this: @This(), handle: usize, ancestor_num: usize) ?usize {
            if (this.get_index_by_handle(handle)) |index| {
                var i = 0;
                var parent_iter = this.get_parent_iter(index);
                while (parent_iter.next()) |parent| {
                    if (i == ancestor_num) {
                        return parent;
                    }
                }
            }
            return null;
        }

        ///////////////////////////
        // Reordering Operations //
        ///////////////////////////

        /// Prepare to move a nodetree to the front of it's parent
        pub fn bring_to_front(this: *@This(), handle: usize) void {
            this.modified = true;
            if (this.reorder_op != null) {
                this.reorder();
            }
            this.reorder_op = .{ .BringToFront = handle };
        }

        /// Queue a nodetree for removal
        pub fn remove(this: *@This(), handle: usize) void {
            this.modified = true;
            if (this.reorder_op != null) {
                this.reorder();
            }
            this.reorder_op = .{ .Remove = handle };
        }

        /// Empty reorder list
        fn reorder(this: *@This()) void {
            if (this.reorder_op) |op| {
                this.run_reorder(op);
            }
            this.reorder_op = null;
        }

        fn run_reorder(this: *@This(), reorder_op: Reorder) void {
            switch (reorder_op) {
                .Remove => |handle| {
                    // Get the node
                    const index = this.get_index_by_handle(handle) orelse return;
                    const node = this.nodes.items[index];
                    const count = node.children + 1;

                    // Get slice of children and rest
                    const rest_slice = this.nodes.items[index + node.children + 1 ..];

                    // Move all elements back by the length of node.children
                    std.mem.copy(Node, this.nodes.items[index .. index + rest_slice.len], rest_slice);

                    // Remove children count from parents
                    var parent_iter = this.get_parent_iter(index);
                    while (parent_iter.next()) |parent| {
                        std.debug.assert(this.nodes.items[parent].children > node.children);
                        this.nodes.items[parent].children -= count;
                    }

                    // Remove unneeded slots
                    this.nodes.shrinkRetainingCapacity(index + rest_slice.len);
                },
                .BringToFront => |handle| {
                    const index = this.get_index_by_handle(handle) orelse return;
                    // Do nothing, the node is already at the front
                    if (index == this.nodes.items.len - 1) return;

                    const node = this.nodes.items[index];
                    const slice = slice: {
                        if (this.get_parent(index)) |parent_index| {
                            const parent = this.nodes.items[parent_index];
                            break :slice this.nodes.items[index .. parent_index + parent.children + 1];
                        } else {
                            break :slice this.nodes.items[index..];
                        }
                    };

                    std.mem.rotate(Node, slice, node.children + 1);
                },
            }
        }
    };
}

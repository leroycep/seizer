//! A simple backend agnostic UI library for zig. Provides tools to quickly layout
//! user interfaces in code and bring them to life on screen. Depends only on the
//! zig std library.

pub const store = @import("ui/store.zig");
pub const Observer = @import("ui/Observer.zig");

const std = @import("std");
const geom = @import("geometry.zig");
const Vec = geom.Vec2;
const Rect = geom.Rect;

const Allocator = std.mem.Allocator;

const List = std.ArrayList;

/// Available layout algorithms
pub const Layout = enum {
    /// Default layout of root - expands children to fill entire space
    Fill,
    /// Default layout. Children are positioned relative to the parent with no
    /// attempt made to prevent overlapping.
    Relative,
    /// Keep elements centered
    Center,
    /// Divide horizontal space equally
    HDiv,
    /// Divide vertical space equally
    VDiv,
    /// Stack elements horizontally
    HList,
    /// Stack elements vertically
    VList,
    // Takes a slice of ints specifying the relative size of each column
    // Grid: []const f32,
};

pub const LayoutData = union(Layout) {
    Fill,
    Relative,
    Center,
    HDiv,
    VDiv,
    HList: struct { left: i32 = 0 },
    VList: struct { top: i32 = 0 },
    // Grid: []const f32,
};

pub const Style = u16;

pub const Node = struct {
    /// Indicates whether the rect has a background
    style: Style,
    /// How many descendants this node has
    children: usize = 0,
    /// A unique handle
    handle: usize = 0,
    /// How much space to leave
    padding: Rect = Rect{ 0, 0, 0, 0 },
    /// Minimum size of the element
    min_size: Vec = Vec{ 0, 0 },
    /// Actual size
    size: Vec = Vec{ 0, 0 },
    /// Screen space rectangle
    bounds: Rect = Rect{ 0, 0, 0, 0 },
    /// What layout function to use on children
    layout: LayoutData = .Relative,
    /// User specified type
    data: ?store.Ref = null,

    pub fn container(node: Node, _layout: Layout) Node {
        var new_node = node;
        new_node.layout = switch (_layout) {
            .Fill => LayoutData.Fill,
            .Relative => LayoutData.Relative,
            .Center => LayoutData.Center,
            .HDiv => LayoutData.HDiv,
            .VDiv => LayoutData.VDiv,
            .HList => LayoutData{ .HList = .{} },
            .VList => LayoutData{ .VList = .{} },
        };
        return new_node;
    }

    pub fn hasStyle(this: @This(), value: Style) @This() {
        var node = this;
        node.style = value;
        return node;
    }

    pub fn dataValue(this: @This(), value: store.Ref) @This() {
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

// pub const Container = struct {
//     style: i16,
//     children: i16,
//     layout: LayoutData,
//     padding: Rect = Rect{ 0, 0, 0, 0 },
// };

// pub const Element = struct {
//     data: ?store.Ref,
//     grow: Vec = Vec{ 0, 0 },
//     min_size: Vec = Vec{ 0, 0 },
// };

/// Provide your basic types
pub const Stage = struct {
    modified: bool,
    /// A monotonically increasing integer assigning new handles
    handle_count: usize,
    root_layout: LayoutData = .Fill,
    /// Array of all ui elements
    nodes: List(Node),

    const Self = @This();

    pub fn init(alloc: Allocator) !@This() {
        var nodelist = try List(Node).initCapacity(alloc, 40);
        return @This(){
            .modified = true,
            .handle_count = 100,
            .nodes = nodelist,
        };
    }

    pub fn deinit(this: *@This()) void {
        this.nodes.deinit();
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
        return handle;
    }

    /// Returns the topmost node at point
    pub fn get_node_at_point(this: @This(), position: Vec) ?Node {
        var i: usize = this.nodes.items.len - 1;
        while (i > 0) : (i -|= 1) {
            const node = this.nodes.items[i];
            if (geom.rect.contains(node.bounds, position)) {
                return node;
            }
            if (i == 0) break;
        }
        return null;
    }

    pub fn get_rects(this: @This()) []const Node {
        return this.nodes.items;
    }

    /// Layout
    pub fn layout(this: *@This(), screen: Rect) void {
        // Nothing to layout
        if (this.nodes.items.len == 0) return;
        // If nothing has been modified, we don't need to proceed
        if (!this.modified) return;

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
    fn run_layout(this: *@This(), which_layout: LayoutData, bounds: Rect, child_index: usize, child_num: usize, child_count: usize) LayoutData {
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

    pub fn update_min_size(this: @This(), handle: usize, min_size: geom.Vec2) void {
        if (this.get_index_by_handle(handle)) |index| {
            this.nodes.items[index].min_size = min_size;
        }
    }

    pub fn get_node(this: @This(), handle: usize) ?Node {
        if (this.get_index_by_handle(handle)) |node| {
            return this.nodes.items[node];
        }
        return null;
    }

    pub fn set_node(this: *@This(), node: Node) void {
        if (this.get_index_by_handle(node.handle)) |i| {
            this.nodes.items[i] = node;
            this.modified = true;
        }
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
    }

    /// Queue a nodetree for removal
    pub fn remove(this: *@This(), handle: usize) void {
        this.modified = true;
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
    }
};

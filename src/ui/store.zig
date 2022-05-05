const std = @import("std");

const Int = i32;
const Float = f32;
const Bytes = []const u8;
const Handle = u16;

pub const Types = enum {
    Int,
    Float,
    Bytes,

    fn real_type(t: Types) type {
        return switch (t) {
            .Int => Int,
            .Float => Float,
            .Bytes => Bytes,
        };
    }
};

pub const Value = union(Types) {
    Int: Int,
    Float: Float,
    Bytes: Bytes,
};

pub const Ref = union(Types) {
    Int: Handle,
    Float: Handle,
    Bytes: Handle,
};

const StoreError = error{
    OutOfBounds,
};

pub const UnmanagedStore = struct {
    int: []Int,
    float: []Float,
    bytes: []Bytes,

    // Assume that if a reference exists, it is valid
    pub fn get(store: @This(), ref: Ref) Value {
        switch (ref) {
            .Int => |handle| {
                std.debug.assert(handle < store.int.len);
                return Value{ .Int = store.int[handle] };
            },
            .Float => |handle| {
                std.debug.assert(handle < store.float.len);
                return Value{ .Float = store.float[handle] };
            },
            .Bytes => |handle| {
                std.debug.assert(handle < store.bytes.len);
                return Value{ .Bytes = store.bytes[handle] };
            },
        }
    }

    pub fn get_ref(store: @This(), T: Types, index: Handle) StoreError!Ref {
        switch (T) {
            .Int => {
                if (index > store.int.len) return error.OutOfBounds;
                return Ref{ .Int = index };
            },
            .Float => {
                if (index > store.float.len) return error.OutOfBounds;
                return Ref{ .Float = index };
            },
            .Bytes => {
                if (index > store.bytes.len) return error.OutOfBounds;
                return Ref{ .Bytes = index };
            },
        }
    }

    pub fn set(store: @This(), comptime T: Types, ref: Ref, value: Types.real_type(T)) void {
        std.debug.assert(T == ref);
        switch (T) {
            .Int => {
                const handle = ref.Int;
                std.debug.assert(handle < store.int.len);
                store.int[handle] = value;
            },
            .Float => {
                const handle = ref.Float;
                std.debug.assert(handle < store.float.len);
                store.float[handle] = value;
            },
            .Bytes => {
                const handle = ref.Bytes;
                std.debug.assert(handle < store.bytes.len);
                store.bytes[handle] = value;
            },
        }
    }
};

test "Unmanaged Store" {
    var int: [4]Int = .{ 0, 1, 2, 3 };
    var float: [4]Float = .{ 0.0, 0.1, 0.2, 0.3 };
    var bytes: [3][]const u8 = .{ "Word", "Wassup?", "Stuff" };

    const store = UnmanagedStore{ .int = &int, .float = &float, .bytes = &bytes };

    const three = try store.get_ref(.Int, 3);
    const point_2 = try store.get_ref(.Float, 2);
    const word = try store.get_ref(.Bytes, 0);

    try std.testing.expectEqual(@as(i32, 3), (store.get(three)).Int);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), (store.get(point_2)).Float, 0.09);
    try std.testing.expectEqualSlices(u8, "Word", (store.get(word)).Bytes);
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    int: std.ArrayList(Int),
    float: std.ArrayList(Float),
    bytes: std.ArrayList(Bytes),
    store: UnmanagedStore,

    pub fn init(allocator: std.mem.Allocator) @This() {
        var this = @This(){
            .allocator = allocator,
            .int = std.ArrayList(Int).init(allocator),
            .float = std.ArrayList(Float).init(allocator),
            .bytes = std.ArrayList(Bytes).init(allocator),
            .store = undefined,
        };
        this.store = UnmanagedStore{
            .int = this.int.items,
            .float = this.float.items,
            .bytes = this.bytes.items,
        };
        return this;
    }

    pub fn deinit(store: *@This()) void {
        for (store.bytes.items) |string| {
            store.allocator.free(string);
        }
        store.store.int = &.{};
        store.store.float = &.{};
        store.store.bytes = &.{};
        store.int.deinit();
        store.float.deinit();
        store.bytes.deinit();
    }

    /// Create a new value of given type, initializing it to zero
    pub fn new(store: *@This(), value: Value) !Ref {
        switch (value) {
            .Int => |val| {
                const handle = @intCast(Handle, store.int.items.len);
                try store.int.append(val);
                store.store.int = store.int.items;
                return store.store.get_ref(value, handle);
            },
            .Float => |val| {
                const handle = @intCast(Handle, store.float.items.len);
                try store.float.append(val);
                store.store.float = store.float.items;
                return store.store.get_ref(value, handle);
            },
            .Bytes => |val| {
                const handle = @intCast(Handle, store.bytes.items.len);
                const new_value = try store.allocator.dupe(u8, val);
                try store.bytes.append(new_value);
                store.store.bytes = store.bytes.items;
                return store.store.get_ref(value, handle);
            },
        }
    }

    pub fn set(store: @This(), comptime T: Types, ref: Ref, value: Types.real_type(T)) !void {
        std.debug.assert(ref == T);
        if (T == .Bytes) {
            std.debug.assert(store.bytes.items.len > ref.Bytes);
            store.allocator.free(store.bytes.items[ref.Bytes]);
            const string = try store.allocator.dupe(u8, value);
            store.store.set(T, ref, string);
        } else {
            store.store.set(T, ref, value);
        }
    }

    pub fn get(store: @This(), ref: Ref) Value {
        return store.store.get(ref);
    }
};

test "Store bytes" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const word_ref = try store.new(.{ .Bytes = "Word" });
    try std.testing.expectEqualSlices(u8, "Word", store.get(word_ref).Bytes);
    try store.set(.Bytes, word_ref, "Word 2: Electric Boogaloo");
    try std.testing.expectEqualSlices(u8, "Word 2: Electric Boogaloo", store.get(word_ref).Bytes);
}

test "Store int" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const int_ref = try store.new(.{ .Int = 0 });
    {
        var int_val = store.get(int_ref).Int;
        int_val += 1;
        try store.set(.Int, int_ref, int_val);
    }
    {
        var int_val = store.get(int_ref).Int;
        int_val += 1;
        try store.set(.Int, int_ref, int_val);
    }
    try std.testing.expectEqual(@as(i32, 2), store.get(int_ref).Int);
}

test "Store float" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const float_ref = try store.new(.{ .Float = 69 });
    {
        var float_val = store.get(float_ref).Float;
        float_val += 0.69;
        try store.set(.Float, float_ref, float_val);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 69.69), store.get(float_ref).Float, 0.1);
}

const std = @import("std");

const Int = i32;
const Float = f32;
const Bytes = []const u8;
const Handle = u16;

const MutBytes = struct {
    data: std.BoundedArray(u8, 64),

    pub fn new() MutBytes {
        var this = MutBytes{ .data = std.BoundedArray(u8, 64).init(0) catch unreachable };
        return this;
    }

    pub fn from(data: []const u8) MutBytes {
        var this = MutBytes{ .data = std.BoundedArray(u8, 64).init(0) catch unreachable };
        this.write(data);
        return this;
    }

    pub fn read(mut_bytes: *MutBytes) []const u8 {
        return mut_bytes.data.constSlice();
    }

    /// Writes to the slice, truncating bytes outside of range
    pub fn write(mut_bytes: *MutBytes, new_data: []const u8) void {
        const len = if (mut_bytes.data.capacity() < new_data.len) mut_bytes.data.capacity() else new_data.len;
        std.mem.copy(u8, mut_bytes.data.buffer[0..len], new_data[0..len]);
        mut_bytes.data.len = len;
    }
};

pub const Types = enum {
    Int,
    Float,
    Bytes,
    MutBytes,

    fn real_type(comptime t: Types) type {
        return switch (t) {
            .Int => Int,
            .Float => Float,
            .Bytes => Bytes,
            .MutBytes => MutBytes,
        };
    }
};

pub const Value = union(Types) {
    Int: Int,
    Float: Float,
    Bytes: Bytes,
    MutBytes: MutBytes,

    pub fn int(value: Int) @This() {
        return .{ .Int = value };
    }
    pub fn float(value: Float) @This() {
        return .{ .Float = value };
    }
    pub fn bytes(value: Bytes) @This() {
        return .{ .Bytes = value };
    }
    pub fn mutbytes(value: []const u8) @This() {
        return .{ .MutBytes = MutBytes.from(value) };
    }
};

pub const Ref = union(Types) {
    Int: Handle,
    Float: Handle,
    Bytes: Handle,
    MutBytes: Handle,
};

const StoreError = error{
    OutOfBounds,
};

pub const UnmanagedStore = struct {
    int: []Int,
    float: []Float,
    bytes: []Bytes,
    mutbytes: []MutBytes,

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
            .MutBytes => |handle| {
                std.debug.assert(handle < store.mutbytes.len);
                return Value{ .MutBytes = store.mutbytes[handle] };
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
            .MutBytes => {
                if (index > store.mutbytes.len) return error.OutOfBounds;
                return Ref{ .MutBytes = index };
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
            .MutBytes => {
                const handle = ref.MutBytes;
                std.debug.assert(handle < store.mutbytes.len);
                store.mutbytes[handle] = value;
            },
        }
    }
};

test "Unmanaged Store" {
    var int: [4]Int = .{ 0, 1, 2, 3 };
    var float: [4]Float = .{ 0.0, 0.1, 0.2, 0.3 };
    var bytes: [3][]const u8 = .{ "Word", "Wassup?", "Stuff" };
    var mutbytes: [3]MutBytes = .{ MutBytes.from("Word"), MutBytes.from("Wassup?"), MutBytes.from("Stuff") };

    const store = UnmanagedStore{ .int = &int, .float = &float, .bytes = &bytes, .mutbytes = &mutbytes };

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
    mutbytes: std.ArrayList(MutBytes),
    store: UnmanagedStore,

    pub fn init(allocator: std.mem.Allocator) @This() {
        var this = @This(){
            .allocator = allocator,
            .int = std.ArrayList(Int).init(allocator),
            .float = std.ArrayList(Float).init(allocator),
            .bytes = std.ArrayList(Bytes).init(allocator),
            .mutbytes = std.ArrayList(MutBytes).init(allocator),
            .store = undefined,
        };
        this.store = UnmanagedStore{
            .int = this.int.items,
            .float = this.float.items,
            .bytes = this.bytes.items,
            .mutbytes = this.mutbytes.items,
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
        store.store.mutbytes = &.{};
        store.int.deinit();
        store.float.deinit();
        store.bytes.deinit();
        store.mutbytes.deinit();
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
            .MutBytes => |val| {
                const handle = @intCast(Handle, store.mutbytes.items.len);
                try store.mutbytes.append(val);
                store.store.mutbytes = store.mutbytes.items;
                return store.store.get_ref(value, handle);
            },
        }
    }

    pub fn set(store: @This(), comptime T: Types, ref: Ref, value: Types.real_type(T)) !void {
        std.debug.assert(ref == T);
        if (T == .Bytes) {
            std.debug.assert(store.bytes.items.len > ref.Bytes);
            // dupe then free to allow self reference
            const string = try store.allocator.dupe(u8, value);
            store.allocator.free(store.bytes.items[ref.Bytes]);
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

test "Store mut bytes" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const word_ref = try store.new(Value.mutbytes("Hello"));
    try std.testing.expectEqualSlices(u8, "Hello", store.get(word_ref).MutBytes.read());
    try store.set(.MutBytes, word_ref, MutBytes.from("Word 2: Electric Boogaloo"));
    try std.testing.expectEqualSlices(u8, "Word 2: Electric Boogaloo", store.get(word_ref).MutBytes.read());

    const long = "this is a really long string that will get truncated instead of returning an error";
    try store.set(.MutBytes, word_ref, MutBytes.from(long));
    try std.testing.expectEqualSlices(u8, "this is a really long string that will get truncated instead of ", store.get(word_ref).MutBytes.read());
}

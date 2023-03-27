const std = @import("std");
const seizer = @import("./seizer.zig");

const SceneTable = struct {
    size: usize,
    alignment: u8,
    deinit: *const fn (*anyopaque) void,
    render: *const fn (*anyopaque, f64) anyerror!void,
    update: ?*const fn (*anyopaque, f64, f64) anyerror!void,
    event: ?*const fn (*anyopaque, seizer.event.Event) anyerror!void,
};

pub fn GetSceneTable(comptime T: type) SceneTable {
    if (!@hasDecl(T, "deinit")) @compileError("fn render(*T) void must be implemented for scenes");
    if (!@hasDecl(T, "render")) @compileError("fn render(*T, f64) !void must be implemented for scenes");

    const deinit_info = @typeInfo(@TypeOf(@field(T, "deinit"))).Fn;
    if (deinit_info.return_type != void) @compileError("fn deinit must return void (no errors).");
    if (deinit_info.params[0].type != *T) @compileError("fn deinit must take a pointer to self.");

    const render_info = @typeInfo(@TypeOf(@field(T, "render"))).Fn;
    if (render_info.params[0].type != *T) @compileError("fn render must take a pointer to self.");
    if (render_info.params[1].type != f64) @compileError("fn render must take an alpha parameter (f64).");

    if (@hasDecl(T, "update")) {
        const update_info = @typeInfo(@TypeOf(@field(T, "update"))).Fn;
        if (update_info.params[0].type != *T) @compileError("fn update must take a pointer to self.");
        if (update_info.params[1].type != f64) @compileError("fn update must take a currentTime parameter (f64).");
        if (update_info.params[2].type != f64) @compileError("fn update must take a delta parameter (f64).");
    }

    if (@hasDecl(T, "event")) {
        const event_info = @typeInfo(@TypeOf(@field(T, "event"))).Fn;
        if (event_info.params[0].type != *T) @compileError("fn event must take a pointer to self.");
        if (event_info.params[1].type != seizer.event.Event) @compileError("fn event must take an event parameter (Event).");
    }

    return SceneTable{
        .size = @sizeOf(T),
        .alignment = std.math.log2_int(u29, @alignOf(T)),
        .deinit = @ptrCast(*const fn (*anyopaque) void, &@field(T, "deinit")),
        .render = @ptrCast(*const fn (*anyopaque, f64) anyerror!void, &@field(T, "render")),
        .update = if (@hasDecl(T, "update")) @ptrCast(*const fn (*anyopaque, f64, f64) anyerror!void, &@field(T, "update")) else null,
        .event = if (@hasDecl(T, "event")) @ptrCast(*const fn (*anyopaque, seizer.event.Event) anyerror!void, &@field(T, "event")) else null,
    };
}

/// This function returns a scene manager for the the passed in Scene types.
/// Scene types must define the following:
/// ```
/// fn init(context: *Context) anyerror!void
/// fn deinit(this: *@This()) void
/// fn render(this: *@This(), alpha: f64) anyerror!void
/// ```
/// Scenes can also define the following types.
/// ```
/// fn event(this: *@This(), event: event.Event) anyerror!void
/// fn update(this: *@This(), currentTime: f64, delta: f64) anyerror!void
/// ```
pub fn Manager(comptime Context: type, comptime Scenes: []const type) type {
    comptime var scene_enum: std.builtin.Type.Enum = std.builtin.Type.Enum{
        .tag_type = usize,
        .fields = &.{},
        .decls = &.{},
        .is_exhaustive = false,
    };
    comptime var scene_table: []const SceneTable = &.{};
    inline for (Scenes, 0..) |t, i| {
        if (!@hasDecl(t, "init")) @compileError("fn init(Context) !T must be implemented for scenes");
        scene_enum.fields = scene_enum.fields ++ [_]std.builtin.Type.EnumField{.{ .name = @typeName(t), .value = i }};
        scene_table = scene_table ++ [_]SceneTable{GetSceneTable(t)};
    }
    const SceneEnum = @Type(.{ .Enum = scene_enum });
    return struct {
        alloc: std.mem.Allocator,
        ctx: *Context,
        scenes: std.ArrayList(ScenePtr),

        pub const Scene = SceneEnum;
        const ScenePtr = struct { which: usize, ptr: *anyopaque };

        pub fn init(alloc: std.mem.Allocator, ctx: *Context, opt: struct { scene_capacity: usize = 5 }) !@This() {
            return @This(){
                .alloc = alloc,
                .ctx = ctx,
                .scenes = try std.ArrayList(ScenePtr).initCapacity(alloc, opt.scene_capacity),
            };
        }

        pub fn deinit(this: *@This()) void {
            while (this.scenes.popOrNull()) |scene| {
                this.dispatch_deinit(scene);
            }
            this.scenes.deinit();
        }

        fn dispatch_deinit(this: *@This(), scene: ScenePtr) void {
            const table = scene_table[scene.which];
            table.deinit(scene.ptr);
            const non_const_ptr = @intToPtr([*]u8, @ptrToInt(scene.ptr));
            this.alloc.rawFree(non_const_ptr[0..table.size], table.alignment, @returnAddress());
        }

        ////////////////////////////
        // Manipulate Scene Stack //
        ////////////////////////////

        pub fn push(this: *@This(), comptime which: SceneEnum) anyerror!void {
            const i = @enumToInt(which);
            const scene = try this.alloc.create(Scenes[i]);
            scene.* = try @field(Scenes[i], "init")(this.ctx);
            try this.scenes.append(.{ .which = i, .ptr = scene });
        }

        pub fn pop(this: *@This()) void {
            const scene = this.scenes.popOrNull() orelse return;
            this.dispatch_deinit(scene);
        }

        pub fn replace(this: *@This(), comptime which: SceneEnum) anyerror!void {
            this.pop();
            _ = try this.push(which);
        }

        ////////////////////////
        // Dispatch Functions //
        ////////////////////////

        /// Run the render function of the current scene.
        pub fn render(this: *@This(), alpha: f64) anyerror!void {
            if (this.scenes.items.len == 0) return;
            const scene = this.scenes.items[this.scenes.items.len - 1];
            try scene_table[scene.which].render(scene.ptr, alpha);
        }

        pub fn update(this: *@This(), currentTime: f64, delta: f64) anyerror!void {
            if (this.scenes.items.len == 0) return;
            const scene = this.scenes.items[this.scenes.items.len - 1];
            if (scene_table[scene.which].update) |updateFn| {
                try updateFn(scene.ptr, currentTime, delta);
            }
        }

        pub fn event(this: *@This(), e: seizer.event.Event) anyerror!void {
            if (this.scenes.items.len == 0) return;
            const scene = this.scenes.items[this.scenes.items.len - 1];
            if (scene_table[scene.which].event) |eventFn| {
                try eventFn(scene.ptr, e);
            }
        }
    };
}

test "Scene Manager" {
    const Ctx = struct { count: usize };
    const Example = struct {
        ctx: *Ctx,
        fn init(ctx: *Ctx) @This() {
            return @This(){
                .ctx = ctx,
            };
        }
        fn deinit(_: *@This()) void {}
        fn update(this: *@This()) void {
            this.ctx.count += 1;
        }
    };
    const SceneManager = Manager(Ctx, &[_]type{Example});
    var ctx = Ctx{ .count = 0 };

    var sm = SceneManager.init(&ctx, std.testing.allocator, .{});
    defer sm.deinit();

    const example_ptr = try sm.push(.Example);
    example_ptr.update();
    try std.testing.expectEqual(@as(usize, 1), ctx.count);

    sm.tick();
    try std.testing.expectEqual(@as(usize, 2), ctx.count);

    sm.pop();
}

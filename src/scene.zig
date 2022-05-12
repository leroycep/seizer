const std = @import("std");
const seizer = @import("./seizer.zig");

/// This function returns a scene manager for the the passed in Scene types.
/// Scene types must define a `fn render(this: *@This(), alpha: f64) anyerror!void`, where
/// `this` is a pointer to the struct the function is declared in. Scenes may also define the following:
/// ```
/// fn init(context: *Context) anyerror!void
/// fn deinit(this: *@This(), currentTime: f64, delta: f64) void
/// fn event(this: *@This(), event: event.Event) anyerror!void
/// fn update(this: *@This(), currentTime: f64, delta: f64) anyerror!void
/// ```
pub fn Manager(comptime Context: type, comptime Scenes: []const type) type {
    comptime var scene_enum: std.builtin.Type.Enum = std.builtin.Type.Enum{
        .layout = .Auto,
        .tag_type = usize,
        .fields = &.{},
        .decls = &.{},
        .is_exhaustive = false,
    };
    inline for (Scenes) |t, i| {
        if (!@hasDecl(t, "render")) @compileError("fn render(T, f64) !void must be implemented for scenes");
        scene_enum.fields = scene_enum.fields ++ [_]std.builtin.Type.EnumField{.{ .name = @typeName(t), .value = i }};
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
            inline for (Scenes) |S, i| {
                if (i == scene.which) {
                    const ptr = @ptrCast(*S, @alignCast(@alignOf(S), scene.ptr));
                    @field(S, "deinit")(ptr);
                    this.alloc.destroy(ptr);
                }
                break;
            }
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
            inline for (Scenes) |S, i| {
                if (i == scene.which) {
                    const ptr = @ptrCast(*S, @alignCast(@alignOf(S), scene.ptr));
                    try @field(S, "render")(ptr, alpha);
                    break;
                }
            }
        }

        pub fn update(this: *@This(), currentTime: f64, delta: f64) anyerror!void {
            if (this.scenes.items.len == 0) return;
            const scene = this.scenes.items[this.scenes.items.len - 1];
            inline for (Scenes) |S, i| {
                if (i == scene.which) {
                    const ptr = @ptrCast(*S, @alignCast(@alignOf(S), scene.ptr));
                    if (@hasDecl(S, "update")) try @field(S, "update")(ptr, currentTime, delta);
                    break;
                }
            }
        }

        pub fn event(this: *@This(), e: seizer.event.Event) anyerror!void {
            if (this.scenes.items.len == 0) return;
            const scene = this.scenes.items[this.scenes.items.len - 1];
            inline for (Scenes) |S, i| {
                if (i == scene.which and @hasDecl(S, "event")) {
                    const ptr = @ptrCast(*S, @alignCast(@alignOf(S), scene.ptr));
                    if (@hasDecl(S, "event")) try @field(S, "event")(ptr, e);
                    break;
                }
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

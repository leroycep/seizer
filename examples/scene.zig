const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");

const SceneManager = seizer.scene.Manager(Context, &[_]type{
    Scene1,
    Scene2,
    Scene3,
});

const Context = struct {
    scene: SceneManager,
    alloc: std.mem.Allocator,
};

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .init = init,
    .event = event,
    .render = render,
    .update = update,
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var context: Context = undefined;

fn init() !void {
    context = .{
        .scene = try SceneManager.init(gpa.allocator(), &context, .{}),
        .alloc = gpa.allocator(),
    };
    try context.scene.push(.Scene1);
}

fn update(a: f64, delta: f64) !void {
    try context.scene.update(a, delta);
}

fn event(e: seizer.event.Event) !void {
    try context.scene.event(e);
    switch (e) {
        .Quit => seizer.quit(),
        else => {},
    }
}

fn render(alpha: f64) !void {
    try context.scene.render(alpha);
}

pub const Scene1 = struct {
    ctx: *Context,
    pub fn init(ctx: *Context) !@This() {
        std.log.info("Enter scene 1", .{});
        return @This(){.ctx = ctx};
    }
    pub fn deinit(_: *@This()) void {
        std.log.info("Exit scene 1", .{});
    }
    pub fn event(this: *@This(), e: seizer.event.Event) !void {
        switch (e) {
            .MouseButtonDown => |mouse| {
                switch (mouse.button) {
                    // .Right => this.ctx.scene.pop(),
                    .Left => try this.ctx.scene.push(.Scene2),
                    else => {},
                }
            },
            else => {},
        }
    }
    pub fn render(this: *@This(), alpha: f64) !void {
        _ = this;
        _ = alpha;

        gl.clearColor(0.7, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
    }
};


pub const Scene2 = struct {
    ctx: *Context,
    string: []const u8,
    pub fn init(ctx: *Context) !@This() {
        std.log.info("Enter scene 2", .{});
        const string = try std.fmt.allocPrint(ctx.alloc, "Help", .{});
        return @This(){.ctx = ctx, .string = string};
    }
    pub fn deinit(this: *@This()) void {
        std.log.info("Exit scene 2", .{});
        this.ctx.alloc.free(this.string);
    }
    pub fn event(this: *@This(), e: seizer.event.Event) !void {
        switch (e) {
            .MouseButtonDown => |mouse| {
                switch (mouse.button) {
                    .Right => this.ctx.scene.pop(),
                    .Left => try this.ctx.scene.replace(.Scene3),
                    else => {},
                }
            },
            else => {},
        }
    }
    pub fn render(this: *@This(), alpha: f64) !void {
        _ = this;
        _ = alpha;

        gl.clearColor(0.5, 0.7, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
    }
};

pub const Scene3 = struct {
    ctx: *Context,
    string: []const u8,
    pub fn init(ctx: *Context) !@This() {
        std.log.info("Enter scene 3", .{});
        const string = try std.fmt.allocPrint(ctx.alloc, "Help", .{});
        return @This(){.ctx = ctx, .string = string};
    }
    pub fn deinit(this: *@This()) void {
        std.log.info("Exit scene 3", .{});
        this.ctx.alloc.free(this.string);
    }
    pub fn event(this: *@This(), e: seizer.event.Event) !void {
        switch (e) {
            .MouseButtonDown => |mouse| {
                switch (mouse.button) {
                    .Right => this.ctx.scene.pop(),
                    // .Left => try this.ctx.scene.push(.Scene2),
                    else => {},
                }
            },
            else => {},
        }
    }
    pub fn render(this: *@This(), alpha: f64) !void {
        _ = this;
        _ = alpha;

        gl.clearColor(0.5, 0.5, 0.7, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
    }
};

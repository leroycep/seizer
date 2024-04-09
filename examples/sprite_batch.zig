pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var player_texture: seizer.Texture = undefined;
var world: *ecs.world_t = undefined;

var spawn_timer_duration: u32 = 10;
var spawn_timer: u32 = 0;

const Position = struct { pos: [2]f32 };
const Velocity = struct { vel: [2]f32 };

pub fn move(it: *ecs.iter_t) callconv(.C) void {
    const p = ecs.field(it, Position, 1).?;
    const v = ecs.field(it, Velocity, 2).?;

    for (0..it.count()) |i| {
        p[i].pos[0] += v[i].vel[0];
        p[i].pos[1] += v[i].vel[1];
    }
}

pub fn init(context: *seizer.Context) !void {
    _ = try context.createWindow(.{
        .title = "Sprite Batch - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(context.gpa, .{});
    errdefer canvas.deinit();

    player_texture = try seizer.Texture.initFromFileContents(context.gpa, @embedFile("assets/wedge.png"), .{});

    world = ecs.init();
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);

    {
        var system_desc = ecs.system_desc_t{};
        system_desc.callback = move;
        system_desc.query.filter.terms[0] = .{ .id = ecs.id(Position) };
        system_desc.query.filter.terms[1] = .{ .id = ecs.id(Velocity) };
        ecs.SYSTEM(world, "move system", ecs.OnUpdate, &system_desc);
    }
}

pub fn deinit(window: *seizer.Window) void {
    _ = window;
    _ = ecs.fini(world);
    canvas.deinit();
}

fn render(window: *seizer.Window) !void {
    _ = ecs.progress(world, 0);

    spawn_timer -|= 1;
    if (spawn_timer <= 1) {
        spawn_timer = spawn_timer_duration;

        const new_sprite = ecs.entity_init(world, &.{});
        _ = ecs.set(world, new_sprite, Position, .{ .pos = .{ 0, 0 } });
        _ = ecs.set(world, new_sprite, Velocity, .{ .vel = .{ 1, 2 } });
    }

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    var filter_desc = ecs.filter_desc_t{};
    filter_desc.terms[0] = .{ .id = ecs.id(Position) };
    const render_filter = try ecs.filter_init(world, &filter_desc);

    var num_sprites: u64 = 0;

    var it = ecs.filter_iter(world, render_filter);
    while (ecs.filter_next(&it)) {
        const p = ecs.field(&it, Position, 1).?;

        num_sprites += it.count();
        for (0..it.count()) |i| {
            canvas.rect(
                p[i].pos,
                [2]f32{ @floatFromInt(player_texture.size[0]), @floatFromInt(player_texture.size[1]) },
                .{ .texture = player_texture.glTexture },
            );
        }
    }
    _ = canvas.printText(.{ 50, 50 }, "sprite count = {}", .{num_sprites}, .{});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const ecs = seizer.flecs;
const std = @import("std");

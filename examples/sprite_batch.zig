pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var player_texture: seizer.Texture = undefined;
var world: *ecs.world_t = undefined;

var spawn_timer_duration: u32 = 10;
var spawn_timer: u32 = 0;
var prng: std.rand.DefaultPrng = undefined;

var frametimes: [256]u64 = [_]u64{0} ** 256;
var frametime_index: usize = 0;

const Position = struct { pos: [2]f32 };
const Velocity = struct { vel: [2]f32 };
const Sprite = struct { texture: *const seizer.Texture };
const WorldBounds = struct { min: [2]f32, max: [2]f32 };

pub fn move(it: *ecs.iter_t) callconv(.C) void {
    const p = ecs.field(it, Position, 1).?;
    const v = ecs.field(it, Velocity, 2).?;

    for (0..it.count()) |i| {
        p[i].pos[0] += v[i].vel[0];
        p[i].pos[1] += v[i].vel[1];
    }
}

pub fn keepInBounds(it: *ecs.iter_t) callconv(.C) void {
    const p = ecs.field(it, Position, 1).?;
    const v = ecs.field(it, Velocity, 2).?;
    const world_bounds = ecs.field(it, WorldBounds, 3).?;

    for (world_bounds) |bound| {
        for (0..it.count()) |i| {
            if (p[i].pos[0] < bound.min[0] and v[i].vel[0] < 0) v[i].vel[0] = -v[i].vel[0];
            if (p[i].pos[1] < bound.min[1] and v[i].vel[1] < 0) v[i].vel[1] = -v[i].vel[1];
            if (p[i].pos[0] > bound.max[0] and v[i].vel[0] > 0) v[i].vel[0] = -v[i].vel[0];
            if (p[i].pos[1] > bound.max[1] and v[i].vel[1] > 0) v[i].vel[1] = -v[i].vel[1];
        }
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
    ecs.COMPONENT(world, Sprite);
    ecs.COMPONENT(world, WorldBounds);

    {
        var system_desc = ecs.system_desc_t{};
        system_desc.callback = move;
        system_desc.query.filter.terms[0] = .{ .id = ecs.id(Position) };
        system_desc.query.filter.terms[1] = .{ .id = ecs.id(Velocity) };
        ecs.SYSTEM(world, "move system", ecs.OnUpdate, &system_desc);
    }
    {
        var system_desc = ecs.system_desc_t{};
        system_desc.callback = keepInBounds;
        system_desc.query.filter.terms[0] = .{ .id = ecs.id(Position) };
        system_desc.query.filter.terms[1] = .{ .id = ecs.id(Velocity) };
        system_desc.query.filter.terms[2] = .{ .id = ecs.id(WorldBounds), .src = .{ .id = ecs.id(WorldBounds) } };
        ecs.SYSTEM(world, "keep in bounds", ecs.OnUpdate, &system_desc);
    }

    prng = std.rand.DefaultPrng.init(1337);
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    _ = ecs.fini(world);
    canvas.deinit();
}

fn render(window: seizer.Window) !void {
    const frame_start = std.time.nanoTimestamp();
    defer {
        const frame_end = std.time.nanoTimestamp();
        const duration: u64 = @intCast(frame_end - frame_start);
        frametimes[frametime_index] = duration;
        frametime_index += 1;
        frametime_index %= frametimes.len;
    }
    _ = ecs.singleton_set(world, WorldBounds, .{ .min = .{ 0, 0 }, .max = window.getSize() });

    _ = ecs.progress(world, 0);

    spawn_timer -|= 1;
    if (spawn_timer <= 1) {
        spawn_timer = spawn_timer_duration;

        const new_sprite = ecs.entity_init(world, &.{});

        const winsize = window.getSize();
        _ = ecs.set(world, new_sprite, Position, .{ .pos = .{
            prng.random().float(f32) * winsize[0],
            prng.random().float(f32) * winsize[1],
        } });
        _ = ecs.set(world, new_sprite, Velocity, .{ .vel = .{
            prng.random().float(f32) * 10 - 5,
            prng.random().float(f32) * 10 - 5,
        } });
        _ = ecs.set(world, new_sprite, Sprite, .{ .texture = &player_texture });
    }

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    var filter_desc = ecs.filter_desc_t{};
    filter_desc.terms[0] = .{ .id = ecs.id(Position) };
    filter_desc.terms[1] = .{ .id = ecs.id(Sprite) };
    const render_filter = try ecs.filter_init(world, &filter_desc);

    var num_sprites: u64 = 0;

    var it = ecs.filter_iter(world, render_filter);
    while (ecs.filter_next(&it)) {
        const positions = ecs.field(&it, Position, 1).?;
        const sprites = ecs.field(&it, Sprite, 2).?;

        num_sprites += it.count();
        for (positions, sprites) |pos, spr| {
            canvas.rect(
                pos.pos,
                [2]f32{ @floatFromInt(spr.texture.size[0]), @floatFromInt(spr.texture.size[1]) },
                .{ .texture = spr.texture.glTexture },
            );
        }
    }

    var text_pos = [2]f32{ 50, 50 };
    const text_size = canvas.printText(text_pos, "sprite count = {}", .{num_sprites}, .{});
    text_pos[1] += text_size[1];

    var frametime_total: f32 = 0;
    for (frametimes) |f| {
        frametime_total += @floatFromInt(f);
    }
    _ = canvas.printText(text_pos, "avg. frametime = {d:0.2} ms", .{frametime_total / @as(f32, @floatFromInt(frametimes.len)) / std.time.ns_per_ms}, .{});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const ecs = seizer.flecs;
const std = @import("std");

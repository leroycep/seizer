pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;
var player_image_size: [2]f32 = .{ 1, 1 };
var player_texture: *seizer.Graphics.Texture = undefined;
var sprites: std.MultiArrayList(Sprite) = .{};

var spawn_timer_duration: u32 = 10;
var spawn_timer: u32 = 0;
var prng: std.rand.DefaultPrng = undefined;

var frametimes: [256]u64 = [_]u64{0} ** 256;
var frametime_index: usize = 0;

const Sprite = struct {
    pos: [2]f32,
    vel: [2]f32,
    size: [2]f32,
};
const WorldBounds = struct { min: [2]f32, max: [2]f32 };

pub fn move(positions: [][2]f32, velocities: []const [2]f32) void {
    for (positions, velocities) |*pos, vel| {
        pos[0] += vel[0];
        pos[1] += vel[1];
    }
}

pub fn keepInBounds(positions: []const [2]f32, velocities: [][2]f32, sizes: []const [2]f32, world_bounds: WorldBounds) void {
    for (positions, velocities, sizes) |pos, *vel, size| {
        if (pos[0] < world_bounds.min[0] and vel[0] < 0) vel[0] = -vel[0];
        if (pos[1] < world_bounds.min[1] and vel[1] < 0) vel[1] = -vel[1];
        if (pos[0] + size[0] > world_bounds.max[0] and vel[0] > 0) vel[0] = -vel[0];
        if (pos[1] + size[1] > world_bounds.max[1] and vel[1] > 0) vel[1] = -vel[1];
    }
}

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "Sprite Batch - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var player_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("assets/wedge.png"));
    defer player_image.deinit();

    player_image_size = [2]f32{
        @floatFromInt(player_image.width),
        @floatFromInt(player_image.height),
    };

    player_texture = try gfx.createTexture(player_image, .{});
    errdefer gfx.destroyTexture(player_texture);

    prng = std.rand.DefaultPrng.init(1337);
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    sprites.deinit(seizer.platform.allocator());
    gfx.destroyTexture(player_texture);
    canvas.deinit();
    gfx.destroy();
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
    const world_bounds = WorldBounds{
        .min = .{ 0, 0 },
        .max = .{ @floatFromInt(window.getSize()[0]), @floatFromInt(window.getSize()[1]) },
    };

    // update sprites
    {
        const sprites_slice = sprites.slice();
        keepInBounds(sprites_slice.items(.pos), sprites_slice.items(.vel), sprites_slice.items(.size), world_bounds);
        move(sprites_slice.items(.pos), sprites_slice.items(.vel));
    }

    spawn_timer -|= 1;
    if (spawn_timer <= 1) {
        spawn_timer = spawn_timer_duration;

        const world_size = [2]f32{
            world_bounds.max[0] - world_bounds.min[0],
            world_bounds.max[1] - world_bounds.min[1],
        };

        const scale = prng.random().float(f32) * 3;
        const size = [2]f32{
            player_image_size[0] * scale,
            player_image_size[1] * scale,
        };
        try sprites.append(seizer.platform.allocator(), .{
            .pos = .{
                prng.random().float(f32) * (world_size[0] - size[0]) + world_bounds.min[0],
                prng.random().float(f32) * (world_size[1] - size[1]) + world_bounds.min[1],
            },
            .vel = .{
                prng.random().float(f32) * 10 - 5,
                prng.random().float(f32) * 10 - 5,
            },
            .size = size,
        });
    }

    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = null,
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    for (sprites.items(.pos), sprites.items(.size)) |pos, size| {
        c.rect(
            pos,
            size,
            .{ .texture = player_texture },
        );
    }

    var text_pos = [2]f32{ 50, 50 };
    const text_size = c.printText(text_pos, "sprite count = {}", .{sprites.len}, .{});
    text_pos[1] += text_size[1];

    var frametime_total: f32 = 0;
    for (frametimes) |f| {
        frametime_total += @floatFromInt(f);
    }
    _ = c.printText(text_pos, "avg. frametime = {d:0.2} ms", .{frametime_total / @as(f32, @floatFromInt(frametimes.len)) / std.time.ns_per_ms}, .{});

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

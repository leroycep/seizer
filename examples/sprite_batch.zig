pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;

var font: seizer.Canvas.Font = undefined;
var canvas: seizer.Canvas = undefined;

var player_image_size: [2]f32 = .{ 1, 1 };
var player_texture: *seizer.Graphics.Texture = undefined;
var sprites: std.MultiArrayList(Sprite) = .{};

var spawn_timer_duration: u32 = 10;
var spawn_timer: u32 = 0;
var prng: std.rand.DefaultPrng = undefined;

var frametimes: [256]u64 = [_]u64{0} ** 256;
var frametime_index: usize = 0;
var between_frame_timer: std.time.Timer = undefined;
var time_between_frames: [256]u64 = [_]u64{0} ** 256;

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
    prng = std.Random.DefaultPrng.init(1337);

    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Sprite Batch - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
        .on_render = render,
    });

    font = try seizer.Canvas.Font.fromFileContents(
        seizer.platform.allocator(),
        gfx,
        @embedFile("./assets/PressStart2P_8.fnt"),
        &.{
            .{ .name = "PressStart2P_8.png", .contents = @embedFile("./assets/PressStart2P_8.png") },
        },
    );
    errdefer font.deinit();

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var player_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("assets/wedge.png"));
    defer player_image.deinit();

    player_image_size = [2]f32{
        @floatFromInt(player_image.width),
        @floatFromInt(player_image.height),
    };

    player_texture = try gfx.createTexture(player_image.toUnmanaged(), .{});
    errdefer gfx.destroyTexture(player_texture);

    between_frame_timer = try std.time.Timer.start();

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    font.deinit();
    sprites.deinit(seizer.platform.allocator());
    gfx.destroyTexture(player_texture);
    canvas.deinit();
    if (swapchain_opt) |swapchain| {
        gfx.destroySwapchain(swapchain);
        swapchain_opt = null;
    }
    display.destroyWindow(window_global);
    gfx.destroy();
    display.destroy();
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    _ = window;
    switch (event) {
        .should_close => seizer.platform.setShouldExit(true),
        .resize, .rescale => {
            if (swapchain_opt) |swapchain| {
                gfx.destroySwapchain(swapchain);
                swapchain_opt = null;
            }
        },
        .input => {},
    }
}

fn render(window: *seizer.Display.Window) !void {
    const window_size = display.windowGetSize(window);

    time_between_frames[frametime_index] = between_frame_timer.lap();

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
        .max = window_size,
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

    // begin rendering
    const window_scale = display.windowGetScale(window);

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size, .scale = window_scale });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    const c = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .window_scale = window_scale,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    for (sprites.items(.pos), sprites.items(.size)) |pos, size| {
        c.rect(
            pos,
            size,
            .{ .texture = player_texture },
        );
    }

    var text_pos = [2]f32{ 50, 50 };
    text_pos[1] += c.printText(&font, text_pos, "sprite count = {}", .{sprites.len}, .{})[1];

    var frametime_total: f32 = 0;
    for (frametimes) |f| {
        frametime_total += @floatFromInt(f);
    }
    text_pos[1] += c.printText(&font, text_pos, "avg. frametime = {d:0.2} ms", .{frametime_total / @as(f32, @floatFromInt(frametimes.len)) / std.time.ns_per_ms}, .{})[1];

    var between_frame_total: f32 = 0;
    for (time_between_frames) |f| {
        between_frame_total += @floatFromInt(f);
    }
    text_pos[1] += c.printText(&font, text_pos, "avg. time between frames = {d:0.2} ms", .{between_frame_total / @as(f32, @floatFromInt(frametimes.len)) / std.time.ns_per_ms}, .{})[1];

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

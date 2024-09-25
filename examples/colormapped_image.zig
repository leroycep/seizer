pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;

var colormap_pipeline: *seizer.Graphics.Pipeline = undefined;
var texture: *seizer.Graphics.Texture = undefined;
var colormap_texture: *seizer.Graphics.Texture = undefined;

var canvas: seizer.Canvas = undefined;

pub const COLORMAP_SHADER_VULKAN = align_source_words: {
    const words_align1 = std.mem.bytesAsSlice(u32, @embedFile("./assets/colormap.frag.spv"));
    const aligned_words: [words_align1.len]u32 = words_align1[0..words_align1.len].*;
    break :align_source_words aligned_words;
};

pub const ColormapUniformData = extern struct {
    colormap_texture_id: u32,
    min_value: f32,
    max_value: f32,
};

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Colormapped Image - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("assets/monochrome.png"));
    defer image.deinit();

    texture = try gfx.createTexture(image.toUnmanaged(), .{});
    errdefer gfx.destroyTexture(texture);

    const colormap_image = seizer.zigimg.ImageUnmanaged{
        .width = seizer.colormaps.turbo_srgb.len,
        .height = 1,
        .pixels = .{ .float32 = @constCast(@as([seizer.colormaps.turbo_srgb.len]seizer.zigimg.color.Colorf32, @bitCast(seizer.colormaps.turbo_srgb))[0..]) },
    };
    colormap_texture = try gfx.createTexture(colormap_image, .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap = .{ .clamp_to_edge, .repeat },
    });
    errdefer gfx.destroyTexture(colormap_texture);

    // create a Canvas pipeline variation to use a colormap texture to render monochrome images
    const colormap_fragment_shader = try gfx.createShader(.{
        .target = .fragment,
        .sampler_count = 1,
        .source = switch (gfx.interface.driver) {
            // .gles3v0 => .{ .glsl = @embedFile("./Canvas/vs.glsl") },
            .vulkan => .{ .spirv = &COLORMAP_SHADER_VULKAN },
            else => |driver| std.debug.panic("colormapped_image example does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    defer gfx.destroyShader(colormap_fragment_shader);

    colormap_pipeline = try canvas.createPipelineVariation(.{
        .fragment_shader = colormap_fragment_shader,
        .extra_uniforms = &[_]seizer.Graphics.Pipeline.UniformDescription{
            .{
                .binding = 2,
                .size = @sizeOf(seizer.Canvas.GlobalConstants),
                .type = .buffer,
                .count = 1,
                .stages = .{ .fragment = true },
            },
        },
    });

    // setup global deinit callback
    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    display.destroyWindow(window_global);
    if (swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    gfx.destroyPipeline(colormap_pipeline);
    gfx.destroyTexture(colormap_texture);
    gfx.destroyTexture(texture);
    canvas.deinit();
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
    const window_scale = display.windowGetScale(window);

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size, .scale = window_scale });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    // split our canvas into two different modes of rendering
    const regular_canvas_rendering = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .window_scale = window_scale,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const colormap_texture_id = canvas.addTexture(colormap_texture);
    const colormap_canvas_rendering = regular_canvas_rendering.withPipeline(colormap_pipeline, &.{
        .{
            .binding = 2,
            .data = std.mem.asBytes(&ColormapUniformData{
                .min_value = 1.0 / @as(f32, @floatFromInt(std.math.maxInt(u16))),
                .max_value = 1,
                .colormap_texture_id = colormap_texture_id,
            }),
        },
    });

    // render the image twice, once with the regular shader and one with our colormapping shader
    regular_canvas_rendering.rect(.{ 0, 0 }, .{ 480, 480 }, .{ .texture = texture });
    colormap_canvas_rendering.rect(.{ 480, 0 }, .{ 480, 480 }, .{ .texture = texture });

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

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

    const default_vertex_shader = try gfx.createShader(.{
        .target = .vertex,
        .sampler_count = 0,
        .source = switch (gfx.interface.driver) {
            // .gles3v0 => .{ .glsl = @embedFile("./Canvas/vs.glsl") },
            .vulkan => .{ .spirv = &seizer.Canvas.DEFAULT_VERTEX_SHADER_VULKAN },
            else => |driver| std.debug.panic("colormapped_image example does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    defer gfx.destroyShader(default_vertex_shader);

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

    colormap_pipeline = try gfx.createPipeline(.{
        .vertex_shader = default_vertex_shader,
        .fragment_shader = colormap_fragment_shader,
        .blend = .{
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .color_op = .add,
            .src_alpha_factor = .src_alpha,
            .dst_alpha_factor = .one_minus_src_alpha,
            .alpha_op = .add,
        },
        .primitive_type = .triangle,
        .push_constants = .{
            .size = @sizeOf(seizer.Canvas.UniformData),
            .stages = .{ .vertex = true, .fragment = true },
        },
        .uniforms = &[_]seizer.Graphics.Pipeline.UniformDescription{
            .{
                .binding = 0,
                .size = @sizeOf(seizer.Canvas.GlobalConstants),
                .type = .buffer,
                .count = 1,
                .stages = .{ .vertex = true },
            },
            .{
                .binding = 1,
                .size = 0,
                .type = .sampler2D,
                .count = 10,
                .stages = .{ .fragment = true },
            },
            .{
                .binding = 2,
                .size = @sizeOf(seizer.Canvas.GlobalConstants),
                .type = .buffer,
                .count = 1,
                .stages = .{ .fragment = true },
            },
        },
        .vertex_layout = &[_]seizer.Graphics.Pipeline.VertexAttribute{
            .{
                .attribute_index = 0,
                .buffer_slot = 0,
                .len = 3,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(seizer.Canvas.Vertex),
                .offset = @offsetOf(seizer.Canvas.Vertex, "pos"),
            },
            .{
                .attribute_index = 1,
                .buffer_slot = 0,
                .len = 2,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(seizer.Canvas.Vertex),
                .offset = @offsetOf(seizer.Canvas.Vertex, "uv"),
            },
            .{
                .attribute_index = 2,
                .buffer_slot = 0,
                .len = 4,
                .type = .u8,
                .normalized = false,
                .stride = @sizeOf(seizer.Canvas.Vertex),
                .offset = @offsetOf(seizer.Canvas.Vertex, "color"),
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
        .resize => {
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

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    gfx.interface.setViewport(gfx.pointer, render_buffer, .{
        .pos = .{ 0, 0 },
        .size = [2]f32{ @floatFromInt(window_size[0]), @floatFromInt(window_size[1]) },
    });
    gfx.interface.setScissor(gfx.pointer, render_buffer, .{ 0, 0 }, window_size);

    const c = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const colormap_texture_id = canvas.addTexture(colormap_texture);

    c.rect(.{ 0, 0 }, .{ 480, 480 }, .{ .texture = texture });

    // TODO: integrate multiple render pipelines into Canvas API?
    // What follows is `canvas.end(render_buffer)`, with a couple modifications, mainly to uploadDescriptors
    canvas.flush();

    const SortByTextureId = struct {
        ids: []const u32,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.ids[a_index] < ctx.ids[b_index];
        }
    };
    canvas.texture_ids.sort(SortByTextureId{ .ids = canvas.texture_ids.values() });

    canvas.graphics.uploadToBuffer(render_buffer, canvas.vertex_buffers[canvas.current_vertex_buffer_index], std.mem.sliceAsBytes(canvas.vertices.items));
    canvas.graphics.uploadDescriptors(render_buffer, colormap_pipeline, seizer.Graphics.Pipeline.UploadDescriptorsOptions{
        .writes = &[_]seizer.Graphics.Pipeline.DescriptorWrite{
            .{
                .binding = 0,
                .offset = 0,
                .data = .{
                    .buffer = &.{
                        std.mem.asBytes(&canvas.projection),
                    },
                },
            },
            .{
                .binding = 1,
                .offset = 0,
                .data = .{
                    .sampler2D = canvas.texture_ids.keys(),
                },
            },
            .{
                .binding = 2,
                .offset = 0,
                .data = .{
                    .buffer = &.{std.mem.asBytes(&ColormapUniformData{
                        .min_value = 1.0 / @as(f32, @floatFromInt(std.math.maxInt(u16))),
                        .max_value = 1,
                        .colormap_texture_id = colormap_texture_id,
                    })},
                },
            },
        },
    });

    canvas.graphics.beginRendering(render_buffer, canvas.begin_rendering_options);
    canvas.graphics.bindPipeline(render_buffer, colormap_pipeline);
    canvas.graphics.bindVertexBuffer(render_buffer, colormap_pipeline, canvas.vertex_buffers[canvas.current_vertex_buffer_index]);

    for (canvas.batches.items) |batch| {
        canvas.graphics.setScissor(render_buffer, batch.scissor.pos, batch.scissor.size);
        canvas.graphics.pushConstants(render_buffer, colormap_pipeline, .{ .vertex = true, .fragment = true }, std.mem.asBytes(&batch.uniforms), 0);
        canvas.graphics.drawPrimitives(render_buffer, batch.vertex_count, 1, batch.vertex_offset, 0);
    }
    canvas.graphics.endRendering(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

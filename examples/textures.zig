//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.

const VERT_SHADER =
    \\ #version 300 es
    \\ layout(location = 0) in vec2 vertexPosition;
    \\ layout(location = 1) in vec2 texturePosition;
    \\
    \\ out vec2 uv;
    \\
    \\ void main() {
    \\   gl_Position = vec4(vertexPosition.xy, 0.0, 1.0);
    \\   uv = texturePosition;
    \\ }
;

const FRAG_SHADER =
    \\ #version 300 es
    \\ in highp vec2 uv;
    \\
    \\ layout(location = 0) out highp vec4 color;
    \\
    \\ uniform highp sampler2D texID;
    \\
    \\ void main() {
    \\   color = texture(texID, uv);
    \\ }
;

const Vertex = extern struct {
    // Position on screen
    x: f32,
    y: f32,
    // Position of in texture
    u: f32,
    v: f32,
};

const VERTS = [_]Vertex{
    // Triangle 1
    .{ .x = -0.5, .y = 0.5, .u = 0.0, .v = 0.0 },
    .{ .x = 0.5, .y = 0.5, .u = 1.0, .v = 0.0 },
    .{ .x = 0.5, .y = -0.5, .u = 1.0, .v = 1.0 },

    // Triangle 2
    .{ .x = -0.5, .y = 0.5, .u = 0.0, .v = 0.0 },
    .{ .x = 0.5, .y = -0.5, .u = 1.0, .v = 1.0 },
    .{ .x = -0.5, .y = -0.5, .u = 0.0, .v = 1.0 },
};

pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var player_texture: *seizer.Graphics.Texture = undefined;
var pipeline: *seizer.Graphics.Pipeline = undefined;
var vertex_buffer: *seizer.Graphics.Buffer = undefined;

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});

    _ = try seizer.platform.createWindow(.{
        .title = "Textures - Seizer Example",
        .on_render = render,
    });

    var player_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("assets/wedge.png"));
    defer player_image.deinit();

    player_texture = try gfx.createTexture(player_image, .{});
    std.log.info("Texture is {}x{} pixels", .{ player_image.width, player_image.height });

    vertex_buffer = try gfx.createBuffer(.{ .size = @sizeOf(@TypeOf(VERTS)) });

    var arena = std.heap.ArenaAllocator.init(seizer.platform.allocator());
    defer arena.deinit();
    const align_allocator = arena.allocator();

    const vertex_shader = try gfx.createShader(.{
        .sampler_count = 1,
        .target = .vertex,
        .source = switch (gfx.interface.driver) {
            .gles3v0 => .{ .glsl = VERT_SHADER },
            .vulkan => align_source_words: {
                const words = std.mem.bytesAsSlice(u32, @embedFile("./assets/textures.vert.spv"));
                const aligned_words = try align_allocator.alloc(u32, words.len);
                for (aligned_words, words) |*aligned_word, word| {
                    aligned_word.* = word;
                }
                break :align_source_words .{ .spirv = aligned_words };
            },
            else => |driver| std.debug.panic("Canvas does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    defer gfx.destroyShader(vertex_shader);
    const fragment_shader = try gfx.createShader(.{
        .sampler_count = 1,
        .target = .fragment,
        .source = switch (gfx.interface.driver) {
            .gles3v0 => .{ .glsl = VERT_SHADER },
            .vulkan => align_source_words: {
                const words = std.mem.bytesAsSlice(u32, @embedFile("./assets/textures.frag.spv"));
                const aligned_words = try align_allocator.alloc(u32, words.len);
                for (aligned_words, words) |*aligned_word, word| {
                    aligned_word.* = word;
                }
                break :align_source_words .{ .spirv = aligned_words };
            },
            else => |driver| std.debug.panic("Canvas does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    defer gfx.destroyShader(fragment_shader);

    pipeline = try gfx.createPipeline(seizer.Graphics.Pipeline.CreateOptions{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .blend = seizer.Graphics.Pipeline.Blend{
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .color_op = .add,
            .src_alpha_factor = .src_alpha,
            .dst_alpha_factor = .one_minus_src_alpha,
            .alpha_op = .add,
        },
        .primitive_type = .triangle,
        .uniforms = &.{
            .{
                .binding = 0,
                .size = 0,
                .type = .sampler2D,
                .count = 1,
                .stages = .{ .fragment = true },
            },
        },
        .push_constants = null,
        .vertex_layout = &[_]seizer.Graphics.Pipeline.VertexAttribute{
            .{
                .attribute_index = 0,
                .buffer_slot = 0,
                .len = 2,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(Vertex),
                .offset = @offsetOf(Vertex, "x"),
            },
            .{
                .attribute_index = 1,
                .buffer_slot = 0,
                .len = 2,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(Vertex),
                .offset = @offsetOf(Vertex, "u"),
            },
        },
    });

    seizer.platform.setDeinitCallback(deinit);
}

/// This is a global deinit, not window specific. This is important because windows can hold onto Graphics resources.
fn deinit() void {
    gfx.destroyPipeline(pipeline);
    gfx.destroyTexture(player_texture);
    gfx.destroyBuffer(vertex_buffer);
    gfx.destroy();
}

fn render(window: seizer.Window) !void {
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = null,
    });

    cmd_buf.uploadUniformTexture(pipeline, 0, 0, player_texture);
    cmd_buf.uploadToBuffer(vertex_buffer, std.mem.asBytes(&VERTS));
    cmd_buf.bindPipeline(pipeline);
    cmd_buf.bindVertexBuffer(pipeline, vertex_buffer);
    cmd_buf.drawPrimitives(6, 1, 0, 0);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

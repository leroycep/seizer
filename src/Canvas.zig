pub const Font = @import("./Canvas/Font.zig");

allocator: std.mem.Allocator,
graphics: seizer.Graphics,

pipeline: *seizer.Graphics.Pipeline,

current_uniform_data: UniformData = .{
    .transform = seizer.geometry.mat4.identity(f32),
    .texture_id = 0,
},
vertices: std.ArrayListUnmanaged(Vertex),
batches: std.ArrayListUnmanaged(Batch),
start_of_batch: u32 = 0,
texture_ids: std.AutoArrayHashMapUnmanaged(*seizer.Graphics.Texture, u32),
next_texture_id: u32 = 0,

window_size: [2]f32 = .{ 1, 1 },
framebuffer_size: [2]f32 = .{ 1, 1 },

blank_texture: *seizer.Graphics.Texture,
font: Font,
font_pages: std.AutoHashMapUnmanaged(u32, FontPage),

vertex_buffers: [10]*seizer.Graphics.Buffer,
current_vertex_buffer_index: usize = 0,

scissor: ?seizer.geometry.Rect(f32) = null,

const Canvas = @This();

pub const RectOptions = struct {
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?*seizer.Graphics.Texture = null,
    /// The top left and bottom right coordinates
    uv: geometry.AABB(f32) = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } },
};

pub const TextOptions = struct {
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    scale: f32 = 1,
    @"align": Align = .left,
    baseline: Baseline = .top,
    font: ?*const Font = null,
    background: ?[4]u8 = null,

    const Align = enum {
        left,
        center,
        right,
    };

    const Baseline = enum {
        top,
        middle,
        bottom,
    };
};

pub const LineOptions = struct {
    width: f32 = 1,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
};

pub fn init(
    allocator: std.mem.Allocator,
    graphics: seizer.Graphics,
    options: struct {
        vertex_buffer_size: usize = 16_384,
        batches: usize = 4096,
        texture_slots: usize = 10,
    },
) !@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const align_allocator = arena.allocator();

    const vertex_shader = try graphics.createShader(seizer.Graphics.Shader.CreateOptions{
        .target = .vertex,
        .sampler_count = 1,
        .source = switch (graphics.interface.driver) {
            .gles3v0 => .{ .glsl = @embedFile("./Canvas/vs.glsl") },
            .vulkan => align_source_words: {
                const words = std.mem.bytesAsSlice(u32, @embedFile("./Canvas/default_shader.vertex.vulkan.spv"));
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
    defer graphics.destroyShader(vertex_shader);

    const fragment_shader = try graphics.createShader(seizer.Graphics.Shader.CreateOptions{
        .target = .fragment,
        .sampler_count = 0,
        .source = switch (graphics.interface.driver) {
            .gles3v0 => .{ .glsl = @embedFile("./Canvas/fs.glsl") },
            .vulkan => align_source_words: {
                const words = std.mem.bytesAsSlice(u32, @embedFile("./Canvas/default_shader.fragment.vulkan.spv"));
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
    defer graphics.destroyShader(fragment_shader);

    const pipeline = try graphics.createPipeline(.{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
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
            .size = @sizeOf(UniformData),
            .stages = .{ .vertex = true, .fragment = true },
        },
        .uniforms = &[_]seizer.Graphics.Pipeline.UniformDescription{
            .{
                .binding = 1,
                .size = 0,
                .type = .sampler2D,
                .count = 10,
                .stages = .{ .fragment = true },
            },
        },
        .vertex_layout = &[_]seizer.Graphics.Pipeline.VertexAttribute{
            .{
                .attribute_index = 0,
                .buffer_slot = 0,
                .len = 2,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(Vertex),
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .attribute_index = 1,
                .buffer_slot = 0,
                .len = 2,
                .type = .f32,
                .normalized = false,
                .stride = @sizeOf(Vertex),
                .offset = @offsetOf(Vertex, "uv"),
            },
            .{
                .attribute_index = 2,
                .buffer_slot = 0,
                .len = 4,
                .type = .u8,
                .normalized = false,
                .stride = @sizeOf(Vertex),
                .offset = @offsetOf(Vertex, "color"),
            },
        },
    });

    var vertices = try std.ArrayListUnmanaged(Vertex).initCapacity(allocator, options.vertex_buffer_size);
    errdefer vertices.deinit(allocator);

    var batches = try std.ArrayListUnmanaged(Batch).initCapacity(allocator, options.batches);
    errdefer batches.deinit(allocator);

    var texture_ids = std.AutoArrayHashMapUnmanaged(*seizer.Graphics.Texture, u32){};
    errdefer texture_ids.deinit(allocator);
    try texture_ids.ensureTotalCapacity(allocator, options.texture_slots);

    var blank_texture_pixels = [_]zigimg.color.Rgba32{
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF },
    };

    const blank_texture = try graphics.createTexture(zigimg.Image{
        .width = 1,
        .height = 1,
        .pixels = .{ .rgba32 = &blank_texture_pixels },
    }, .{});
    errdefer graphics.destroyTexture(blank_texture);

    var font = try Font.parse(allocator, @embedFile("./Canvas/PressStart2P_8.fnt"));
    errdefer font.deinit();

    var font_pages = std.AutoHashMapUnmanaged(u32, FontPage){};
    errdefer font_pages.deinit(allocator);

    var page_name_iter = font.pages.iterator();
    while (page_name_iter.next()) |font_page| {
        const page_id = font_page.key_ptr.*;
        const page_name = font_page.value_ptr.*;

        try font_pages.ensureUnusedCapacity(allocator, 1);

        const image_bytes = if (std.mem.eql(u8, page_name, "PressStart2P_8.png")) @embedFile("./Canvas/PressStart2P_8.png") else return error.FontPageImageNotFound;

        var font_image = try zigimg.Image.fromMemory(allocator, image_bytes);
        defer font_image.deinit();

        const page_texture = try graphics.createTexture(font_image, .{});

        font_pages.putAssumeCapacity(page_id, .{
            .texture = page_texture,
            .size = .{
                @as(f32, @floatFromInt(font_image.width)),
                @as(f32, @floatFromInt(font_image.height)),
            },
        });
    }

    var vertex_buffers: [10]*seizer.Graphics.Buffer = undefined;
    for (vertex_buffers[0..]) |*vertex_buffer| {
        vertex_buffer.* = try graphics.createBuffer(.{ .size = @intCast(options.vertex_buffer_size * @sizeOf(Vertex)) });
        errdefer graphics.destroyBuffer(vertex_buffer);
    }

    return .{
        .allocator = allocator,
        .graphics = graphics,

        .pipeline = pipeline,
        .vertices = vertices,
        .batches = batches,
        .texture_ids = texture_ids,

        .blank_texture = blank_texture,
        .font = font,
        .font_pages = font_pages,

        .vertex_buffers = vertex_buffers,
    };
}

pub fn deinit(this: *@This()) void {
    this.graphics.destroyPipeline(this.pipeline);

    this.texture_ids.deinit(this.allocator);
    this.batches.deinit(this.allocator);
    this.vertices.deinit(this.allocator);
    this.font.deinit();

    this.graphics.destroyTexture(this.blank_texture);
    var page_name_iter = this.font_pages.iterator();
    while (page_name_iter.next()) |entry| {
        this.graphics.destroyTexture(entry.value_ptr.texture);
    }
    this.font_pages.deinit(this.allocator);

    for (this.vertex_buffers) |vertex_buffer| {
        this.graphics.destroyBuffer(vertex_buffer);
    }
}

pub const BeginOptions = struct {
    window_size: [2]u32,
    invert_y: bool = false,
    scissor: ?seizer.geometry.Rect(f32) = null,
};

pub fn begin(this: *@This(), command_buffer: seizer.Graphics.CommandBuffer, options: BeginOptions) Transformed {
    this.window_size = [2]f32{
        @floatFromInt(options.window_size[0]),
        @floatFromInt(options.window_size[1]),
    };
    this.framebuffer_size = [2]f32{
        @floatFromInt(options.window_size[0]),
        @floatFromInt(options.window_size[1]),
    };

    this.current_uniform_data = .{
        .transform = geometry.mat4.orthographic(
            f32,
            0,
            this.window_size[0],
            if (options.invert_y) 0 else this.window_size[1],
            if (options.invert_y) this.window_size[1] else 0,
            0,
            1,
        ),
        .texture_id = 0,
    };
    this.batches.shrinkRetainingCapacity(0);
    this.vertices.shrinkRetainingCapacity(0);
    this.start_of_batch = 0;
    this.setScissor(options.scissor);

    this.texture_ids.shrinkRetainingCapacity(0);
    this.texture_ids.putAssumeCapacityNoClobber(this.blank_texture, 0);
    command_buffer.uploadUniformTexture(this.pipeline, 1, 0, this.blank_texture);
    this.next_texture_id = 1;

    return Transformed{
        .canvas = this,
        .command_buffer = command_buffer,
        .transform = this.current_uniform_data.transform,
    };
}

pub fn end(this: *@This(), command_buffer: seizer.Graphics.CommandBuffer) void {
    this.flush(command_buffer);

    command_buffer.uploadToBuffer(this.vertex_buffers[this.current_vertex_buffer_index], std.mem.sliceAsBytes(this.vertices.items));
    command_buffer.bindPipeline(this.pipeline);
    command_buffer.bindVertexBuffer(this.pipeline, this.vertex_buffers[this.current_vertex_buffer_index]);

    for (this.batches.items) |batch| {
        command_buffer.pushConstants(this.pipeline, .{ .vertex = true, .fragment = true }, std.mem.asBytes(&batch.uniforms), 0);
        command_buffer.drawPrimitives(batch.vertex_count, 1, batch.vertex_offset, 0);
    }
}

// TODO: Potentially rename? Might switch to using a stencil buffer instead of gl scissor
pub fn setScissor(this: *@This(), new_scissor_rect: ?seizer.geometry.Rect(f32)) void {
    if (true) return;
    if (this.scissor != null and new_scissor_rect != null) {
        if (!this.scissor.?.eq(new_scissor_rect.?)) {
            this.flush();
            this.scissor = new_scissor_rect.?;
            // gl.scissor(
            //     @intFromFloat(new_scissor_rect.?.pos[0]),
            //     @intFromFloat(this.window_size[1] - new_scissor_rect.?.pos[1] - new_scissor_rect.?.size[1]),
            //     @intFromFloat(new_scissor_rect.?.size[0]),
            //     @intFromFloat(new_scissor_rect.?.size[1]),
            // );
        }
    } else if (this.scissor == null and new_scissor_rect != null) {
        this.flush();
        // gl.enable(gl.SCISSOR_TEST);
        this.scissor = new_scissor_rect;
        // gl.scissor(
        //     @intFromFloat(new_scissor_rect.?.pos[0]),
        //     @intFromFloat(this.window_size[1] - new_scissor_rect.?.pos[1] - new_scissor_rect.?.size[1]),
        //     @intFromFloat(new_scissor_rect.?.size[0]),
        //     @intFromFloat(new_scissor_rect.?.size[1]),
        // );
    } else if (this.scissor != null and new_scissor_rect == null) {
        this.flush();
        // gl.disable(gl.SCISSOR_TEST);
        this.scissor = null;
    }
}

// pub fn rect(this: *@This(), pos: [2]f32, size: [2]f32, options: RectOptions) void {
//     const transformed = Transformed{ .canvas = this, .transform = geometry.mat4.identity(f32) };
//     return transformed.rect(pos, size, options);
// }

// pub fn line(this: *@This(), pos1: [2]f32, pos2: [2]f32, options: LineOptions) void {
//     const transformed = Transformed{ .canvas = this, .transform = geometry.mat4.identity(f32) };
//     return transformed.line(pos1, pos2, options);
// }

// pub fn writeText(this: *@This(), pos: [2]f32, text: []const u8, options: TextOptions) [2]f32 {
//     const transformed = Transformed{ .canvas = this, .transform = geometry.mat4.identity(f32) };
//     return transformed.writeText(pos, text, options);
// }

// pub fn printText(this: *@This(), pos: [2]f32, comptime fmt: []const u8, args: anytype, options: TextOptions) [2]f32 {
//     const transformed = Transformed{ .canvas = this, .transform = geometry.mat4.identity(f32) };
//     return transformed.printText(pos, fmt, args, options);
// }

// pub fn textWriter(this: *@This(), options: TextWriter.Options) TextWriter {
//     return TextWriter{
//         .transformed = .{
//             .canvas = this,
//             .transform = geometry.mat4.identity(f32),
//         },
//         .options = options,
//         .direction = 1,
//         .current_pos = options.pos,
//     };
// }

pub const TextWriter = struct {
    transformed: Transformed,
    options: Options,
    direction: f32,
    current_pos: [2]f32,
    size: [2]f32 = .{ 0, 0 },
    bg_rect_start: ?[2]f32 = null,

    pub const Options = struct {
        pos: [2]f32 = .{ 0, 0 },
        color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        scale: f32 = 1,
        background: ?[4]u8 = null,
    };

    pub fn addCharacter(this: *@This(), character: u21) void {
        if (character == '\n') {
            this.current_pos[1] += this.transformed.canvas.font.lineHeight * this.options.scale;
            this.current_pos[0] = this.options.pos[0];

            this.size = .{
                @max(this.current_pos[0] - this.options.pos[0], this.size[0]),
                @max(this.current_pos[1] - this.options.pos[1] + this.transformed.canvas.font.lineHeight * this.options.scale, this.size[1]),
            };
            return;
        }
        const glyph = this.transformed.canvas.font.glyphs.get(character) orelse {
            log.warn("No glyph found for character \"{}\"", .{std.fmt.fmtSliceHexLower(std.mem.asBytes(&character))});
            return;
        };

        const xadvance = (glyph.xadvance * this.options.scale);
        const offset = [2]f32{
            glyph.offset[0] * this.options.scale,
            glyph.offset[1] * this.options.scale,
        };

        if (this.options.background) |bg| {
            this.transformed.rect(
                this.current_pos,
                .{
                    xadvance,
                    this.transformed.canvas.font.lineHeight * this.options.scale,
                },
                .{
                    .color = bg,
                },
            );
        }

        const font_page = this.transformed.canvas.font_pages.get(glyph.page) orelse {
            log.warn("Unknown font page {} for glyph \"{}\"", .{ glyph.page, std.fmt.fmtSliceHexLower(std.mem.asBytes(&character)) });
            return;
        };

        this.transformed.rect(
            .{
                this.current_pos[0] + offset[0],
                this.current_pos[1] + offset[1],
            },
            .{
                glyph.size[0] * this.options.scale,
                glyph.size[1] * this.options.scale,
            },
            .{
                .texture = font_page.texture,
                .uv = .{
                    .min = .{
                        glyph.pos[0] / font_page.size[0],
                        glyph.pos[1] / font_page.size[1],
                    },
                    .max = .{
                        (glyph.pos[0] + glyph.size[0]) / font_page.size[0],
                        (glyph.pos[1] + glyph.size[1]) / font_page.size[1],
                    },
                },
                .color = this.options.color,
            },
        );

        this.current_pos[0] += this.direction * xadvance;
        this.size = .{
            @max(this.current_pos[0] - this.options.pos[0], this.size[0]),
            @max(this.current_pos[1] - this.options.pos[1] + this.transformed.canvas.font.lineHeight * this.options.scale, this.size[1]),
        };
    }

    pub fn addText(this: *@This(), text: []const u8) void {
        for (text) |char| {
            this.addCharacter(char);
        }
    }

    pub fn writer(this: *@This()) Writer {
        return Writer{
            .context = this,
        };
    }

    pub const Writer = std.io.Writer(*@This(), error{}, write);

    pub fn write(this: *@This(), bytes: []const u8) error{}!usize {
        this.addText(bytes);
        return bytes.len;
    }
};

/// Low-level function used to implement higher-level draw operations. Handles applying the transform.
pub fn addVertices(this: *@This(), command_buffer: seizer.Graphics.CommandBuffer, transform: [4][4]f32, texture: *seizer.Graphics.Texture, vertices: []const Vertex) void {
    if (vertices.len == 0) return;

    const texture_slot = this.texture_ids.getOrPutAssumeCapacity(texture);
    if (!texture_slot.found_existing) {
        texture_slot.value_ptr.* = this.next_texture_id;
        command_buffer.uploadUniformTexture(this.pipeline, 1, texture_slot.value_ptr.*, texture);

        this.next_texture_id += 1;
    }

    const is_transform_changed = !std.meta.eql(transform, this.current_uniform_data.transform);
    const is_texture_changed = this.current_uniform_data.texture_id != texture_slot.value_ptr.*;
    if (is_transform_changed or is_texture_changed) {
        this.flush(command_buffer);
        this.current_uniform_data = .{
            .transform = transform,
            .texture_id = texture_slot.value_ptr.*,
        };
    }

    this.vertices.appendSliceAssumeCapacity(vertices);
}

pub fn flush(this: *@This(), command_buffer: seizer.Graphics.CommandBuffer) void {
    if (this.vertices.items.len - this.start_of_batch == 0) return;
    _ = command_buffer;

    this.batches.append(this.allocator, Batch{
        .vertex_count = @as(u32, @intCast(this.vertices.items.len)) - this.start_of_batch,
        .vertex_offset = this.start_of_batch,
        .uniforms = this.current_uniform_data,
    }) catch @panic("OutOfMemory for uniform batches");

    this.start_of_batch = @intCast(this.vertices.items.len);
}

/// A transformed canvas
pub const Transformed = struct {
    canvas: *Canvas,
    command_buffer: seizer.Graphics.CommandBuffer,
    transform: [4][4]f32,
    scissor: ?seizer.geometry.Rect(f32) = null,

    pub fn rect(this: @This(), pos: [2]f32, size: [2]f32, options: RectOptions) void {
        this.canvas.addVertices(this.command_buffer, this.transform, options.texture orelse this.canvas.blank_texture, &.{
            // triangle 1
            .{
                .pos = pos,
                .uv = options.uv.min,
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0] + size[0],
                    pos[1],
                },
                .uv = .{
                    options.uv.max[0],
                    options.uv.min[1],
                },
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0],
                    pos[1] + size[1],
                },
                .uv = .{
                    options.uv.min[0],
                    options.uv.max[1],
                },
                .color = options.color,
            },

            // triangle 2
            .{
                .pos = .{
                    pos[0] + size[0],
                    pos[1] + size[1],
                },
                .uv = options.uv.max,
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0],
                    pos[1] + size[1],
                },
                .uv = .{
                    options.uv.min[0],
                    options.uv.max[1],
                },
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0] + size[0],
                    pos[1],
                },
                .uv = .{
                    options.uv.max[0],
                    options.uv.min[1],
                },
                .color = options.color,
            },
        });
    }

    pub fn writeText(this: @This(), pos: [2]f32, text: []const u8, options: TextOptions) [2]f32 {
        const font = options.font orelse &this.canvas.font;
        const text_size = font.textSize(text, options.scale);

        const x: f32 = switch (options.@"align") {
            .left => pos[0],
            .center => pos[0] - text_size[0] / 2,
            .right => pos[0] - text_size[0],
        };
        const y: f32 = switch (options.baseline) {
            .top => pos[1],
            .middle => pos[1] - text_size[1] / 2,
            .bottom => pos[1] - text_size[1],
        };
        var text_writer = this.textWriter(.{
            .pos = .{ x, y },
            .scale = options.scale,
            .color = options.color,
            .background = options.background,
        });
        text_writer.writer().writeAll(text) catch {};
        return text_writer.size;
    }

    pub fn printText(this: @This(), pos: [2]f32, comptime fmt: []const u8, args: anytype, options: TextOptions) [2]f32 {
        const font = options.font orelse &this.canvas.font;
        const text_size = font.fmtTextSize(fmt, args, options.scale);

        const x: f32 = switch (options.@"align") {
            .left => pos[0],
            .center => pos[0] - text_size[0] / 2,
            .right => pos[0] - text_size[0],
        };
        const y: f32 = switch (options.baseline) {
            .top => pos[1],
            .middle => pos[1] - text_size[1] / 2,
            .bottom => pos[1] - text_size[1],
        };

        var text_writer = this.textWriter(.{
            .pos = .{ x, y },
            .scale = options.scale,
            .color = options.color,
        });
        text_writer.writer().print(fmt, args) catch {};

        return text_writer.size;
    }

    pub fn textWriter(this: @This(), options: TextWriter.Options) TextWriter {
        return TextWriter{
            .transformed = this,
            .options = options,
            .direction = 1,
            .current_pos = options.pos,
        };
    }

    pub fn line(this: @This(), pos1: [2]f32, pos2: [2]f32, options: LineOptions) void {
        const half_width = options.width / 2;
        const half_length = geometry.vec.magnitude(2, f32, .{
            pos2[0] - pos1[0],
            pos2[1] - pos1[1],
        }) / 2;

        const forward = geometry.vec.normalize(2, f32, .{
            pos2[0] - pos1[0],
            pos2[1] - pos1[1],
        });
        const right = geometry.vec.normalize(2, f32, .{
            forward[1],
            -forward[0],
        });
        const midpoint = [2]f32{
            (pos1[0] + pos2[0]) / 2,
            (pos1[1] + pos2[1]) / 2,
        };

        const back_left = [2]f32{
            midpoint[0] - half_length * forward[0] - half_width * right[0],
            midpoint[1] - half_length * forward[1] - half_width * right[1],
        };
        const back_right = [2]f32{
            midpoint[0] - half_length * forward[0] + half_width * right[0],
            midpoint[1] - half_length * forward[1] + half_width * right[1],
        };
        const fore_left = [2]f32{
            midpoint[0] + half_length * forward[0] - half_width * right[0],
            midpoint[1] + half_length * forward[1] - half_width * right[1],
        };
        const fore_right = [2]f32{
            midpoint[0] + half_length * forward[0] + half_width * right[0],
            midpoint[1] + half_length * forward[1] + half_width * right[1],
        };

        this.canvas.addVertices(this.command_buffer, this.transform, this.canvas.blank_texture, &.{
            .{
                .pos = back_left,
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_left,
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = back_right,
                .uv = .{ 0, 0 },
                .color = options.color,
            },

            .{
                .pos = back_right,
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_left,
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_right,
                .uv = .{ 0, 0 },
                .color = options.color,
            },
        });
    }

    pub fn transformed(this: @This(), transform: [4][4]f32) Transformed {
        return Transformed{
            .canvas = this.canvas,
            .transform = geometry.mat4.mul(f32, this.transform, transform),
            .scissor = this.scissor,
        };
    }

    pub fn scissored(this: @This(), new_scissor_rect_opt: ?seizer.geometry.Rect(f32)) Transformed {
        var scissor_rect_opt = new_scissor_rect_opt;
        if (new_scissor_rect_opt) |new_scissor_rect| {
            // TODO: the scissor doesn't work correctly if the canvas has been rotated or skewed
            const top_left = new_scissor_rect.bottomLeft();
            const bottom_right = new_scissor_rect.topRight();

            const point1_transformed = geometry.mat4.mulVec(f32, this.transform, top_left ++ [2]f32{ 0, 1 })[0..2].*;
            const point2_transformed = geometry.mat4.mulVec(f32, this.transform, bottom_right ++ [2]f32{ 0, 1 })[0..2].*;

            const top_left_transformed = [2]f32{
                @min(point1_transformed[0], point2_transformed[0]),
                @min(point1_transformed[1], point2_transformed[1]),
            };
            const bottom_right_transformed = [2]f32{
                @max(point1_transformed[0], point2_transformed[0]),
                @max(point1_transformed[1], point2_transformed[1]),
            };

            scissor_rect_opt = seizer.geometry.Rect(f32){
                .pos = top_left_transformed,
                .size = [2]f32{
                    bottom_right_transformed[0] - top_left_transformed[0],
                    bottom_right_transformed[1] - top_left_transformed[1],
                },
            };
        }
        return Transformed{
            .canvas = this.canvas,
            .command_buffer = this.command_buffer,
            .transform = this.transform,
            .scissor = scissor_rect_opt,
        };
    }
};

const FontPage = struct {
    texture: *seizer.Graphics.Texture,
    size: [2]f32,
};

const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

const UniformData = extern struct {
    transform: [4][4]f32,
    texture_id: u32,
};

const Batch = struct {
    vertex_count: u32,
    vertex_offset: u32,
    uniforms: UniformData,
};

const log = std.log.scoped(.Canvas);
const std = @import("std");
const seizer = @import("seizer.zig");
const zigimg = @import("zigimg");
const geometry = @import("./geometry.zig");

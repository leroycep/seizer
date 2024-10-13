pub const Font = @import("./Canvas/Font.zig");

allocator: std.mem.Allocator,
graphics: seizer.Graphics,

default_vertex_shader: *seizer.Graphics.Shader,
default_fragment_shader: *seizer.Graphics.Shader,
pipeline: *seizer.Graphics.Pipeline,

vertices: std.ArrayListUnmanaged(Vertex),
batches: std.ArrayListUnmanaged(Batch),
current_batch: Batch,
texture_ids: std.AutoArrayHashMapUnmanaged(*seizer.Graphics.Texture, u32),
next_texture_id: u32 = 0,

window_size: [2]f32 = .{ 1, 1 },

blank_texture: *seizer.Graphics.Texture,

// TODO: dynamically allocate more when necessary
vertex_buffers: [10]*seizer.Graphics.Buffer,
current_vertex_buffer_index: usize = 0,
frame_arena: std.heap.ArenaAllocator,

begin_rendering_options: seizer.Graphics.RenderBuffer.BeginRenderingOptions,
scissor: ?seizer.geometry.Rect(f32) = null,
projection: [4][4]f32,

const Canvas = @This();

pub const RectOptions = struct {
    depth: f32 = 0.5,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?*seizer.Graphics.Texture = null,
    /// The top left and bottom right coordinates
    uv: geometry.AABB(f32) = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } },
};

pub const TextOptions = struct {
    depth: f32 = 0.5,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    scale: f32 = 1,
    @"align": Align = .left,
    baseline: Baseline = .top,
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
    depth: f32 = 0.5,
    width: f32 = 1,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
};

pub const PipelineVariationOptions = struct {
    vertex_shader: ?*seizer.Graphics.Shader = null,
    fragment_shader: ?*seizer.Graphics.Shader = null,
    // Uniforms beyond the global constants the default pipeline uses
    extra_uniforms: ?[]const seizer.Graphics.Pipeline.UniformDescription = null,
};

pub const DEFAULT_VERTEX_SHADER_VULKAN = align_source_words: {
    const words_align1 = std.mem.bytesAsSlice(u32, @embedFile("./Canvas/default_shader.vertex.vulkan.spv"));
    const aligned_words: [words_align1.len]u32 = words_align1[0..words_align1.len].*;
    break :align_source_words aligned_words;
};

pub const DEFAULT_FRAGMENT_SHADER_VULKAN = align_source_words: {
    const words_align1 = std.mem.bytesAsSlice(u32, @embedFile("./Canvas/default_shader.fragment.vulkan.spv"));
    const aligned_words: [words_align1.len]u32 = words_align1[0..words_align1.len].*;
    break :align_source_words aligned_words;
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
    const default_vertex_shader = try graphics.createShader(seizer.Graphics.Shader.CreateOptions{
        .target = .vertex,
        .sampler_count = 1,
        .source = switch (graphics.interface.driver) {
            .gles3v0 => .{ .glsl = @embedFile("./Canvas/vs.glsl") },
            .vulkan => .{ .spirv = &DEFAULT_VERTEX_SHADER_VULKAN },
            else => |driver| std.debug.panic("Canvas does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    errdefer graphics.destroyShader(default_vertex_shader);

    const default_fragment_shader = try graphics.createShader(seizer.Graphics.Shader.CreateOptions{
        .target = .fragment,
        .sampler_count = 0,
        .source = switch (graphics.interface.driver) {
            .gles3v0 => .{ .glsl = @embedFile("./Canvas/fs.glsl") },
            .vulkan => .{ .spirv = &DEFAULT_FRAGMENT_SHADER_VULKAN },
            else => |driver| std.debug.panic("Canvas does not support {} driver", .{driver}),
        },
        .entry_point_name = "main",
    });
    errdefer graphics.destroyShader(default_fragment_shader);

    const pipeline = try graphics.createPipeline(.{
        .vertex_shader = default_vertex_shader,
        .fragment_shader = default_fragment_shader,
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
                .binding = 0,
                .size = @sizeOf(GlobalConstants),
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
        },
        .vertex_layout = &Vertex.ATTRIBUTES,
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

    const blank_texture = try graphics.createTexture(zigimg.ImageUnmanaged{
        .width = 1,
        .height = 1,
        .pixels = .{ .rgba32 = &blank_texture_pixels },
    }, .{});
    errdefer graphics.destroyTexture(blank_texture);

    var vertex_buffers: [10]*seizer.Graphics.Buffer = undefined;
    for (vertex_buffers[0..]) |*vertex_buffer| {
        vertex_buffer.* = try graphics.createBuffer(.{ .size = @intCast(options.vertex_buffer_size * @sizeOf(Vertex)) });
        errdefer graphics.destroyBuffer(vertex_buffer);
    }

    return .{
        .allocator = allocator,
        .graphics = graphics,

        .default_vertex_shader = default_vertex_shader,
        .default_fragment_shader = default_fragment_shader,
        .pipeline = pipeline,
        .vertices = vertices,
        .batches = batches,
        .current_batch = undefined,
        .texture_ids = texture_ids,

        .blank_texture = blank_texture,

        .vertex_buffers = vertex_buffers,
        .begin_rendering_options = undefined,
        .projection = undefined,

        .frame_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(this: *@This()) void {
    this.graphics.destroyShader(this.default_vertex_shader);
    this.graphics.destroyShader(this.default_fragment_shader);
    this.graphics.destroyPipeline(this.pipeline);

    this.texture_ids.deinit(this.allocator);
    this.batches.deinit(this.allocator);
    this.vertices.deinit(this.allocator);

    this.graphics.destroyTexture(this.blank_texture);

    for (this.vertex_buffers) |vertex_buffer| {
        this.graphics.destroyBuffer(vertex_buffer);
    }

    this.frame_arena.deinit();
}

pub const BeginOptions = struct {
    window_size: [2]f32,
    window_scale: f32,
    invert_y: bool = false,
    scissor: ?struct { [2]i32, [2]u32 } = null,
    clear_color: [4]f32,
};

pub fn begin(this: *@This(), render_buffer: *seizer.Graphics.RenderBuffer, options: BeginOptions) Transformed {
    this.window_size = options.window_size;

    _ = this.frame_arena.reset(.retain_capacity);
    this.batches.shrinkRetainingCapacity(0);
    this.vertices.shrinkRetainingCapacity(0);
    this.projection = switch (this.graphics.interface.driver) {
        .gles3v0 => geometry.mat4.orthographic(f32, 0, this.window_size[0], if (options.invert_y) 0 else this.window_size[1], if (options.invert_y) this.window_size[1] else 0, 0, 1),
        .vulkan => geometry.mat4.mulAll(f32, &.{
            geometry.mat4.translate(f32, .{ -1.0, -1.0, 0.0 }),
            geometry.mat4.scale(f32, .{ 2.0 / (options.window_size[0] * options.window_scale), 2.0 / (options.window_size[1] * options.window_scale), 0.0 }),
        }),
        else => |driver| std.debug.panic("Canvas does not support {} driver", .{driver}),
    };

    this.begin_rendering_options = .{
        .clear_color = options.clear_color,
    };

    this.current_batch = .{
        .pipeline = this.pipeline,
        .extra_uniform_buffers = null,
        .vertex_offset = 0,
        .vertex_count = undefined,
        .scissor = .{ .pos = .{ 0, 0 }, .size = .{ @intFromFloat(options.window_size[0] * options.window_scale), @intFromFloat(options.window_size[1] * options.window_scale) } },
        .uniforms = .{
            .transform = geometry.mat4.scale(f32, .{
                options.window_scale,
                options.window_scale,
                1.0,
            }),
            .texture_id = 0,
        },
    };

    this.texture_ids.shrinkRetainingCapacity(0);
    this.texture_ids.putAssumeCapacityNoClobber(this.blank_texture, 0);
    this.next_texture_id = 1;

    this.graphics.setViewport(render_buffer, .{
        .pos = .{ 0, 0 },
        .size = [2]f32{ options.window_size[0] * options.window_scale, options.window_size[1] * options.window_scale },
    });

    return Transformed{
        .canvas = this,
        .render_buffer = render_buffer,
        .transform = this.current_batch.uniforms.transform,
        .scissor = this.current_batch.scissor,
        .pipeline = this.current_batch.pipeline,
        .extra_uniforms = this.current_batch.extra_uniform_buffers,
    };
}

pub fn addTexture(this: *@This(), texture: *seizer.Graphics.Texture) u32 {
    const gop = this.texture_ids.getOrPut(this.allocator, texture) catch unreachable;
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }
    gop.value_ptr.* = this.next_texture_id;
    this.next_texture_id += 1;
    return gop.value_ptr.*;
}

pub fn end(this: *@This(), render_buffer: *seizer.Graphics.RenderBuffer) void {
    this.flush();

    const SortByTextureId = struct {
        ids: []const u32,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.ids[a_index] < ctx.ids[b_index];
        }
    };
    this.texture_ids.sort(SortByTextureId{ .ids = this.texture_ids.values() });

    this.graphics.uploadToBuffer(render_buffer, this.vertex_buffers[this.current_vertex_buffer_index], std.mem.sliceAsBytes(this.vertices.items));

    var descriptor_sets = std.AutoArrayHashMap(?[]const ExtraUniformBuffer, *seizer.Graphics.DescriptorSet).init(this.allocator);
    defer descriptor_sets.deinit();

    var descriptor_writes = std.ArrayList(seizer.Graphics.Pipeline.DescriptorWrite).init(this.allocator);
    defer descriptor_writes.deinit();
    for (this.batches.items) |batch| {
        const gop = descriptor_sets.getOrPut(batch.extra_uniform_buffers) catch unreachable;
        if (gop.found_existing) continue;

        descriptor_writes.shrinkRetainingCapacity(0);
        descriptor_writes.appendSlice(&[_]seizer.Graphics.Pipeline.DescriptorWrite{
            .{
                .binding = 0,
                .offset = 0,
                .data = .{
                    .buffer = &.{
                        std.mem.asBytes(&this.projection),
                    },
                },
            },
            .{
                .binding = 1,
                .offset = 0,
                .data = .{
                    .sampler2D = this.texture_ids.keys(),
                },
            },
        }) catch unreachable;
        if (batch.extra_uniform_buffers) |extra_uniform_list| {
            for (extra_uniform_list) |extra_uniform| {
                descriptor_writes.append(seizer.Graphics.Pipeline.DescriptorWrite{
                    .binding = extra_uniform.binding,
                    .offset = 0,
                    .data = .{
                        .buffer = &.{extra_uniform.data},
                    },
                }) catch unreachable;
            }
        }
        gop.value_ptr.* = this.graphics.uploadDescriptors(render_buffer, batch.pipeline, seizer.Graphics.Pipeline.UploadDescriptorsOptions{
            .writes = descriptor_writes.items,
        });
    }

    this.graphics.beginRendering(render_buffer, this.begin_rendering_options);
    this.graphics.bindVertexBuffer(render_buffer, this.pipeline, this.vertex_buffers[this.current_vertex_buffer_index]);

    // for pipelines used
    // bind descriptor set
    for (this.batches.items) |batch| {
        this.graphics.bindPipeline(render_buffer, batch.pipeline);
        this.graphics.bindDescriptorSet(render_buffer, batch.pipeline, descriptor_sets.get(batch.extra_uniform_buffers).?);
        this.graphics.setScissor(render_buffer, batch.scissor.pos, batch.scissor.size);
        this.graphics.pushConstants(render_buffer, this.pipeline, .{ .vertex = true, .fragment = true }, std.mem.asBytes(&batch.uniforms), 0);
        this.graphics.drawPrimitives(render_buffer, batch.vertex_count, 1, batch.vertex_offset, 0);
    }
    // end pipelines used

    this.graphics.endRendering(render_buffer);
}

pub fn setScissor(this: *@This(), pos: [2]i32, size: [2]u32) void {
    this.flush();
    this.current_batch.scissor = .{ pos, size };
}

pub fn createPipelineVariation(this: *@This(), options: PipelineVariationOptions) !*seizer.Graphics.Pipeline {
    const uniform_descriptions = try this.allocator.alloc(seizer.Graphics.Pipeline.UniformDescription, if (options.extra_uniforms) |u| u.len + 2 else 2);
    defer this.allocator.free(uniform_descriptions);
    @memcpy(uniform_descriptions[0..2], &[_]seizer.Graphics.Pipeline.UniformDescription{
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
    });

    if (options.extra_uniforms) |extra_uniforms| {
        @memcpy(uniform_descriptions[2..], extra_uniforms);
    }

    const pipeline = try this.graphics.createPipeline(.{
        .base_pipeline = this.pipeline,
        .vertex_shader = options.vertex_shader orelse this.default_vertex_shader,
        .fragment_shader = options.fragment_shader orelse this.default_vertex_shader,
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
        .uniforms = uniform_descriptions,
        .vertex_layout = &Vertex.ATTRIBUTES,
    });

    return pipeline;
}

/// Low-level function used to implement higher-level draw operations. Handles applying the transform.
pub fn addVertices(this: *@This(), pipeline: *seizer.Graphics.Pipeline, extra_uniform_buffers: ?[]const ExtraUniformBuffer, transform: [4][4]f32, texture: *seizer.Graphics.Texture, scissor: Scissor, vertices: []const Vertex) void {
    if (vertices.len == 0) return;

    const texture_id = this.addTexture(texture);

    const is_pipeline_changed = pipeline != this.current_batch.pipeline;
    const is_extra_uniform_buffers_changed = !std.meta.eql(extra_uniform_buffers, this.current_batch.extra_uniform_buffers);
    const is_transform_changed = !std.meta.eql(transform, this.current_batch.uniforms.transform);
    const is_texture_changed = this.current_batch.uniforms.texture_id != texture_id;
    const is_scissor_changed = !std.meta.eql(scissor, this.current_batch.scissor);
    if (is_pipeline_changed or is_extra_uniform_buffers_changed or is_transform_changed or is_texture_changed or is_scissor_changed) {
        this.flush();
        this.current_batch.uniforms = .{
            .transform = transform,
            .texture_id = texture_id,
        };
        this.current_batch.scissor = scissor;
        this.current_batch.pipeline = pipeline;
        this.current_batch.extra_uniform_buffers = extra_uniform_buffers;
    }

    this.vertices.appendSliceAssumeCapacity(vertices);
}

pub fn flush(this: *@This()) void {
    if (this.vertices.items.len - this.current_batch.vertex_offset == 0) return;

    this.batches.append(this.allocator, Batch{
        .pipeline = this.current_batch.pipeline,
        .extra_uniform_buffers = this.current_batch.extra_uniform_buffers,
        .vertex_offset = this.current_batch.vertex_offset,
        .vertex_count = @as(u32, @intCast(this.vertices.items.len)) - this.current_batch.vertex_offset,
        .uniforms = this.current_batch.uniforms,
        .scissor = this.current_batch.scissor,
    }) catch @panic("OutOfMemory for uniform batches");

    this.current_batch.vertex_offset = @intCast(this.vertices.items.len);
}

/// A transformed canvas
pub const Transformed = struct {
    canvas: *Canvas,
    render_buffer: *seizer.Graphics.RenderBuffer,
    transform: [4][4]f32,
    scissor: Scissor,
    pipeline: *seizer.Graphics.Pipeline,
    extra_uniforms: ?[]const ExtraUniformBuffer = null,

    pub fn rect(this: @This(), pos: [2]f32, size: [2]f32, options: RectOptions) void {
        this.canvas.addVertices(this.pipeline, this.extra_uniforms, this.transform, options.texture orelse this.canvas.blank_texture, this.scissor, &.{
            // triangle 1
            .{
                .pos = pos ++ [1]f32{options.depth},
                .uv = options.uv.min,
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0] + size[0],
                    pos[1],
                    options.depth,
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
                    options.depth,
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
                    options.depth,
                },
                .uv = options.uv.max,
                .color = options.color,
            },
            .{
                .pos = .{
                    pos[0],
                    pos[1] + size[1],
                    options.depth,
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
                    options.depth,
                },
                .uv = .{
                    options.uv.max[0],
                    options.uv.min[1],
                },
                .color = options.color,
            },
        });
    }

    pub fn writeText(this: @This(), font: *const Font, pos: [2]f32, text: []const u8, options: TextOptions) [2]f32 {
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
        var text_writer = this.textLayoutWriter(font, .{
            .pos = .{ x, y },
            .scale = options.scale,
            .color = options.color,
        });
        text_writer.writer().writeAll(text) catch {};
        return text_writer.text_layout.size;
    }

    pub fn printText(this: @This(), font: *const Font, pos: [2]f32, comptime fmt: []const u8, args: anytype, options: TextOptions) [2]f32 {
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

        var text_writer = this.textLayoutWriter(font, .{
            .pos = .{ x, y },
            .scale = options.scale,
            .color = options.color,
        });
        text_writer.writer().print(fmt, args) catch {};

        return text_writer.text_layout.size;
    }

    pub const TextLayoutWriter = Font.TextLayoutWriter(WriteGlyphContext, writeGlyph);
    pub const TextLayoutOptions = struct {
        pos: [2]f32 = .{ 0, 0 },
        scale: f32 = 1,
        color: [4]u8,
    };
    pub fn textLayoutWriter(this: @This(), font: *const Font, options: TextLayoutOptions) TextLayoutWriter {
        return TextLayoutWriter{
            .context = .{
                .transformed = this,
                .font = font,
                .options = options,
            },
            .text_layout = .{
                .glyphs = &font.glyphs,
                .text = "",
                .line_height = font.line_height,
                .current_offset = options.pos,
                .options = .{ .pos = options.pos, .scale = options.scale },
            },
        };
    }

    const WriteGlyphContext = struct {
        transformed: Transformed,
        font: *const Font,
        options: TextLayoutOptions,
    };

    fn writeGlyph(ctx: WriteGlyphContext, item: Font.TextLayout.Item) void {
        const font_page = ctx.font.pages.get(item.glyph.page);
        const texture = if (font_page) |page| page.texture else ctx.transformed.canvas.blank_texture;
        const texture_sizef: [2]f32 = if (font_page) |page| .{ @floatFromInt(page.size[0]), @floatFromInt(page.size[1]) } else .{ 1, 1 };
        ctx.transformed.rect(
            item.pos,
            item.size,
            .{
                .texture = texture,
                .uv = .{
                    .min = .{
                        item.glyph.pos[0] / texture_sizef[0],
                        item.glyph.pos[1] / texture_sizef[1],
                    },
                    .max = .{
                        (item.glyph.pos[0] + item.glyph.size[0]) / texture_sizef[0],
                        (item.glyph.pos[1] + item.glyph.size[1]) / texture_sizef[1],
                    },
                },
                .color = ctx.options.color,
            },
        );
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

        this.canvas.addVertices(this.pipeline, this.extra_uniforms, this.transform, this.canvas.blank_texture, this.scissor, &.{
            .{
                .pos = back_left ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_left ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = back_right ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },

            .{
                .pos = back_right ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_left ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },
            .{
                .pos = fore_right ++ [1]f32{options.depth},
                .uv = .{ 0, 0 },
                .color = options.color,
            },
        });
    }

    pub fn transformed(this: @This(), transform: [4][4]f32) Transformed {
        return Transformed{
            .render_buffer = this.render_buffer,
            .canvas = this.canvas,
            .transform = geometry.mat4.mul(f32, this.transform, transform),
            .scissor = this.scissor,
            .pipeline = this.pipeline,
            .extra_uniforms = this.extra_uniforms,
        };
    }

    pub fn scissored(this: @This(), new_scissor_rect: seizer.geometry.Rect(f32)) Transformed {
        // TODO: the scissor doesn't work correctly if the canvas has been rotated or skewed
        const top_left = new_scissor_rect.topLeft();
        const bottom_right = new_scissor_rect.bottomRight();

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

        const new_scissor = Scissor{
            .pos = [2]i32{
                @intFromFloat(top_left_transformed[0]),
                @intFromFloat(top_left_transformed[1]),
            },
            .size = [2]u32{
                @intFromFloat(bottom_right_transformed[0] - top_left_transformed[0]),
                @intFromFloat(bottom_right_transformed[1] - top_left_transformed[1]),
            },
        };
        return Transformed{
            .canvas = this.canvas,
            .render_buffer = this.render_buffer,
            .transform = this.transform,
            .scissor = new_scissor,
            .pipeline = this.pipeline,
            .extra_uniforms = this.extra_uniforms,
        };
    }

    pub fn withPipeline(this: @This(), new_pipeline: *seizer.Graphics.Pipeline, extra_uniforms_opt: ?[]const ExtraUniformBuffer) Transformed {
        if (extra_uniforms_opt) |extra_uniforms_borrowed| {
            const extra_uniforms = this.canvas.frame_arena.allocator().alloc(ExtraUniformBuffer, extra_uniforms_borrowed.len) catch unreachable;
            for (extra_uniforms, extra_uniforms_borrowed) |*uniform, uniform_borrowed| {
                const data = this.canvas.frame_arena.allocator().dupe(u8, uniform_borrowed.data) catch unreachable;
                uniform.* = .{
                    .binding = uniform_borrowed.binding,
                    .data = data,
                };
            }

            return Transformed{
                .render_buffer = this.render_buffer,
                .canvas = this.canvas,
                .transform = this.transform,
                .scissor = this.scissor,
                .pipeline = new_pipeline,
                .extra_uniforms = extra_uniforms,
            };
        } else {
            return Transformed{
                .render_buffer = this.render_buffer,
                .canvas = this.canvas,
                .transform = this.transform,
                .scissor = this.scissor,
                .pipeline = new_pipeline,
                .extra_uniforms = null,
            };
        }
    }
};

pub const Vertex = struct {
    pos: [3]f32,
    uv: [2]f32,
    color: [4]u8,

    pub const ATTRIBUTES = [_]seizer.Graphics.Pipeline.VertexAttribute{
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
    };
};

pub const GlobalConstants = extern struct {
    projection: [4][4]f32,
};

pub const UniformData = extern struct {
    transform: [4][4]f32,
    texture_id: u32,
};

const Batch = struct {
    pipeline: *seizer.Graphics.Pipeline,
    extra_uniform_buffers: ?[]const ExtraUniformBuffer,

    vertex_count: u32,
    vertex_offset: u32,
    uniforms: UniformData,
    scissor: Scissor,
};

pub const ExtraUniformBuffer = struct {
    binding: u32,
    data: []const u8,
};

pub const Scissor = extern struct {
    pos: [2]i32,
    size: [2]u32,
};

const log = std.log.scoped(.Canvas);
const std = @import("std");
const seizer = @import("seizer.zig");
const zigimg = @import("zigimg");
const geometry = @import("./geometry.zig");

pub const Font = @import("./Canvas/Font.zig");

allocator: std.mem.Allocator,
program: gl.Uint,
uniforms: UniformLocations,
current_texture: ?gl.Uint,
vertices: std.ArrayListUnmanaged(Vertex),
transform_stack: std.ArrayListUnmanaged([4][4]f32),
scissor_stack: std.ArrayListUnmanaged([2][2]f32),

window_size: [2]f32 = .{ 1, 1 },
framebuffer_size: [2]f32 = .{ 1, 1 },

blank_texture: gl.Uint,
font: Font,
font_pages: std.AutoHashMapUnmanaged(u32, FontPage),

vbo: gl.Uint,

const Canvas = @This();

pub fn init(
    allocator: std.mem.Allocator,
    options: struct {
        vertex_buffer_size: usize = 16_384,
        transform_stack_size: usize = 128,
        scissor_stack_size: usize = 32,
    },
) !@This() {
    // Text shader
    const program = gl.createProgram();
    errdefer gl.deleteProgram(program);

    {
        const vs = gl.createShader(gl.VERTEX_SHADER);
        defer gl.deleteShader(vs);
        const vs_src = @embedFile("./Canvas/vs.glsl");
        gl.shaderSource(vs, 1, &[_][*:0]const u8{vs_src}, &[_]c_int{@intCast(vs_src.len)});
        gl.compileShader(vs);

        var vertex_shader_status: gl.Int = undefined;
        gl.getShaderiv(vs, gl.COMPILE_STATUS, &vertex_shader_status);

        if (vertex_shader_status != gl.TRUE) {
            var shader_log: [1024:0]u8 = undefined;
            var shader_log_len: gl.Sizei = undefined;
            gl.getShaderInfoLog(vs, shader_log.len, &shader_log_len, &shader_log);
            std.log.warn("{s}:{} error compiling shader: {s}", .{ @src().file, @src().line, shader_log });
            return error.ShaderCompilation;
        }

        const fs = gl.createShader(gl.FRAGMENT_SHADER);
        defer gl.deleteShader(fs);
        const fs_src = @embedFile("./Canvas/fs.glsl");
        gl.shaderSource(fs, 1, &[_][*:0]const u8{fs_src}, &[_]c_int{@intCast(fs_src.len)});
        gl.compileShader(fs);

        var fragment_shader_status: gl.Int = undefined;
        gl.getShaderiv(fs, gl.COMPILE_STATUS, &fragment_shader_status);

        if (fragment_shader_status != gl.TRUE) {
            var shader_log: [1024:0]u8 = undefined;
            var shader_log_len: gl.Sizei = undefined;
            gl.getShaderInfoLog(fs, shader_log.len, &shader_log_len, &shader_log);
            std.log.warn("{s}:{} error compiling shader: {s}", .{ @src().file, @src().line, shader_log });
            return error.ShaderCompilation;
        }

        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        defer {
            gl.detachShader(program, vs);
            gl.detachShader(program, fs);
        }

        gl.linkProgram(program);

        var program_status: gl.Int = undefined;
        gl.getProgramiv(program, gl.LINK_STATUS, &program_status);

        if (program_status != gl.TRUE) {
            var program_log: [1024:0]u8 = undefined;
            var program_log_len: gl.Sizei = undefined;
            gl.getProgramInfoLog(program, program_log.len, &program_log_len, &program_log);
            std.log.warn("{s}:{} error compiling program: {s}\n", .{ @src().file, @src().line, program_log });
            return error.ShaderCompilation;
        }
    }

    var vertices = try std.ArrayListUnmanaged(Vertex).initCapacity(allocator, options.vertex_buffer_size);
    errdefer vertices.deinit(allocator);

    var transform_stack = try std.ArrayListUnmanaged([4][4]f32).initCapacity(allocator, options.transform_stack_size);
    errdefer transform_stack.deinit(allocator);

    var scissor_stack = try std.ArrayListUnmanaged([2][2]f32).initCapacity(allocator, options.scissor_stack_size);
    errdefer scissor_stack.deinit(allocator);

    var blank_texture: gl.Uint = undefined;
    gl.genTextures(1, &blank_texture);
    errdefer gl.deleteTextures(1, &blank_texture);
    {
        const BLANK_IMAGE = [_][4]u8{
            .{ 0xFF, 0xFF, 0xFF, 0xFF },
        };

        gl.bindTexture(gl.TEXTURE_2D, blank_texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, std.mem.sliceAsBytes(&BLANK_IMAGE).ptr);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    }

    var font = try Font.parse(allocator, @embedFile("./Canvas/PressStart2P_8.fnt"));
    errdefer font.deinit();

    var font_pages = std.AutoHashMapUnmanaged(u32, FontPage){};
    errdefer font_pages.deinit(allocator);

    var page_name_iter = font.pages.iterator();
    while (page_name_iter.next()) |font_page| {
        const page_id = font_page.key_ptr.*;
        const page_name = font_page.value_ptr.*;

        const image_bytes = if (std.mem.eql(u8, page_name, "PressStart2P_8.png")) @embedFile("./Canvas/PressStart2P_8.png") else return error.FontPageImageNotFound;

        var font_image = try zigimg.Image.fromMemory(allocator, image_bytes);
        defer font_image.deinit();

        var page_texture: gl.Uint = undefined;
        gl.genTextures(1, &page_texture);
        errdefer gl.deleteTextures(1, &page_texture);

        gl.bindTexture(gl.TEXTURE_2D, page_texture);
        switch (font_image.pixels) {
            .rgba32 => |rgba32| gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                @as(gl.Sizei, @intCast(font_image.width)),
                @as(gl.Sizei, @intCast(font_image.width)),
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                std.mem.sliceAsBytes(rgba32).ptr,
            ),
            .grayscale8 => |grayscale8| gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.ALPHA,
                @as(gl.Sizei, @intCast(font_image.width)),
                @as(gl.Sizei, @intCast(font_image.width)),
                0,
                gl.ALPHA,
                gl.UNSIGNED_BYTE,
                std.mem.sliceAsBytes(grayscale8).ptr,
            ),
            else => std.debug.panic("Font image formant {s} is unimplemented", .{@tagName(font_image.pixels)}),
        }
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        try font_pages.put(allocator, page_id, .{
            .texture = page_texture,
            .size = .{
                @as(f32, @floatFromInt(font_image.width)),
                @as(f32, @floatFromInt(font_image.height)),
            },
        });
    }

    var vbo: gl.Uint = undefined;
    gl.genBuffers(1, &vbo);

    const projection = gl.getUniformLocation(program, "projection");
    const texture = gl.getUniformLocation(program, "texture_handle");

    return .{
        .allocator = allocator,
        .program = program,
        .uniforms = .{
            .projection = projection,
            .texture = texture,
        },
        .current_texture = null,
        .vertices = vertices,
        .transform_stack = transform_stack,
        .scissor_stack = scissor_stack,

        .blank_texture = blank_texture,
        .font = font,
        .font_pages = font_pages,

        .vbo = vbo,
    };
}

pub fn deinit(this: *@This()) void {
    gl.deleteProgram(this.program);
    this.vertices.deinit(this.allocator);
    this.transform_stack.deinit(this.allocator);
    this.scissor_stack.deinit(this.allocator);
    this.font.deinit();

    var page_name_iter = this.font_pages.iterator();
    while (page_name_iter.next()) |entry| {
        gl.deleteTextures(1, &entry.value_ptr.*.texture);
    }
    this.font_pages.deinit(this.allocator);

    gl.deleteBuffers(1, &this.vbo);
}

pub const BeginOptions = struct {
    window_size: [2]f32,
    framebuffer_size: [2]f32,
    invert_y: bool = false,
};

pub fn begin(this: *@This(), options: BeginOptions) void {
    this.window_size = options.window_size;
    this.framebuffer_size = options.framebuffer_size;

    const projection = geometry.mat4.orthographic(
        f32,
        0,
        this.window_size[0],
        if (options.invert_y) 0 else this.window_size[1],
        if (options.invert_y) this.window_size[1] else 0,
        -1,
        1,
    );

    this.transform_stack.shrinkRetainingCapacity(0);
    this.transform_stack.appendAssumeCapacity(projection);

    const scissor = [2][2]f32{
        .{ 0, 0 },
        this.window_size,
    };
    const pixel_size = [2]f32{
        this.framebuffer_size[0] / this.window_size[0],
        this.framebuffer_size[1] / this.window_size[1],
    };
    gl.enable(gl.SCISSOR_TEST);
    gl.scissor(
        @intFromFloat(scissor[0][0] * pixel_size[0]),
        @intFromFloat((this.window_size[1] - scissor[0][1] - scissor[1][1]) * pixel_size[1]),
        @intFromFloat(scissor[1][0] * pixel_size[0]),
        @intFromFloat(scissor[1][1] * pixel_size[1]),
    );
    this.scissor_stack.shrinkRetainingCapacity(0);
    this.scissor_stack.appendAssumeCapacity(scissor);

    // TEXTURE_UNIT0
    gl.useProgram(this.program);
    gl.uniform1i(this.uniforms.texture, 0);
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &this.transform_stack.items[0][0]);

    this.vertices.shrinkRetainingCapacity(0);

    gl.enable(gl.BLEND);
    gl.disable(gl.DEPTH_TEST);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.activeTexture(gl.TEXTURE0);
}

/// Multiplies transform by the previous transform and pushes the resulting transform to the stack.
/// It then uploads the new transform. Will flush vertices using the current transform.
pub fn pushTransform(this: *@This(), transform: [4][4]f32) void {
    std.debug.assert(this.transform_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }
    const transform_multiplied = geometry.mat4.mul(f32, this.transform_stack.items[this.transform_stack.items.len - 1], transform);
    this.transform_stack.appendAssumeCapacity(transform_multiplied);
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &transform_multiplied[0]);
}

/// Pops the current transform and applies the previous transform. Will flush vertices using the
/// current transform.
pub fn popTransform(this: *@This()) void {
    std.debug.assert(this.transform_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }
    _ = this.transform_stack.pop();
    gl.uniformMatrix4fv(this.uniforms.projection, 1, gl.FALSE, &this.transform_stack.items[this.transform_stack.items.len - 1][0]);
}

pub fn pushScissor(this: *@This(), pos: [2]f32, size: [2]f32) void {
    std.debug.assert(this.scissor_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }

    // constrain scissor to previous scissor
    const prev_scissor = this.scissor_stack.items[this.scissor_stack.items.len - 1];
    const prev_bottom_right = [2]f32{
        prev_scissor[0][0] + prev_scissor[1][0],
        prev_scissor[0][1] + prev_scissor[1][1],
    };
    const top_left = .{
        std.math.clamp(pos[0], prev_scissor[0][0], prev_bottom_right[0]),
        std.math.clamp(pos[1], prev_scissor[0][1], prev_bottom_right[1]),
    };
    const bottom_right = .{
        std.math.clamp(pos[0] + size[0], prev_scissor[0][0], prev_bottom_right[0]),
        std.math.clamp(pos[1] + size[1], prev_scissor[0][1], prev_bottom_right[1]),
    };
    const scissor = .{
        top_left,
        .{
            bottom_right[0] - top_left[0],
            bottom_right[1] - top_left[1],
        },
    };

    // update gl.scissor
    const pixel_size = [2]f32{
        this.framebuffer_size[0] / this.window_size[0],
        this.framebuffer_size[1] / this.window_size[1],
    };
    gl.scissor(
        @intFromFloat(scissor[0][0] * pixel_size[0]),
        @intFromFloat((this.window_size[1] - scissor[0][1] - scissor[1][1]) * pixel_size[1]),
        @intFromFloat(scissor[1][0] * pixel_size[0]),
        @intFromFloat(scissor[1][1] * pixel_size[1]),
    );
    this.scissor_stack.appendAssumeCapacity(scissor);
}

pub fn popScissor(this: *@This()) void {
    std.debug.assert(this.scissor_stack.items.len > 0);
    if (this.vertices.items.len > 0) {
        this.flush();
    }
    _ = this.scissor_stack.pop();
    const pixel_size = [2]f32{
        this.framebuffer_size[0] / this.window_size[0],
        this.framebuffer_size[1] / this.window_size[1],
    };
    const scissor = this.scissor_stack.items[this.scissor_stack.items.len - 1];
    gl.scissor(
        @intFromFloat(scissor[0][0] * pixel_size[0]),
        @intFromFloat((this.window_size[1] - scissor[0][1] - scissor[1][1]) * pixel_size[1]),
        @intFromFloat(scissor[1][0] * pixel_size[0]),
        @intFromFloat(scissor[1][1] * pixel_size[1]),
    );
}

pub fn getScissor(this: *@This()) struct { pos: [2]f32, size: [2]f32 } {
    return .{
        .pos = this.scissor_stack.items[this.scissor_stack.items.len - 1][0],
        .size = this.scissor_stack.items[this.scissor_stack.items.len - 1][1],
    };
}

pub const RectOptions = struct {
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?gl.Uint = null,
    /// The top left and bottom right coordinates
    uv: geometry.AABB(f32) = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } },
};

pub fn rect(this: *@This(), pos: [2]f32, size: [2]f32, options: RectOptions) void {
    this.vertices.ensureUnusedCapacity(this.allocator, 6) catch {
        this.flush();
    };
    if (!std.meta.eql(options.texture, this.current_texture)) {
        this.flush();
        this.current_texture = options.texture;
    }

    this.vertices.appendSliceAssumeCapacity(&.{
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

pub const TriangleOptions = struct {
    pos: [3][2]f32,
    color: [4]u8 = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    texture: ?gl.Uint = null,
    /// The top left and bottom right coordinates
    uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
};

pub fn triangle(this: *@This(), options: TriangleOptions) void {
    this.vertices.ensureUnusedCapacity(this.allocator, 3) catch {
        this.flush();
    };
    if (!std.meta.eql(options.texture, this.current_texture)) {
        this.flush();
        this.current_texture = options.texture;
    }

    this.vertices.appendSliceAssumeCapacity(&.{
        .{
            .pos = options.pos[0],
            .uv = options.uv[0],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[0],
        },
        .{
            .pos = options.pos[1],
            .uv = options.uv[1],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[1],
        },
        .{
            .pos = options.pos[2],
            .uv = options.uv[2],
            .color = options.color,
            .shape = options.shape,
            .bary = options.bary[2],
        },
    });
}

pub const TextOptions = struct {
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    scale: f32 = 1,
    @"align": Align = .left,
    baseline: Baseline = .top,
    font: ?*const Font = null,

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

pub fn writeText(this: *@This(), pos: [2]f32, text: []const u8, options: TextOptions) [2]f32 {
    const font = options.font orelse &this.font;
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
    });
    text_writer.writer().writeAll(text) catch {};
    return text_writer.size;
}

pub fn printText(this: *@This(), pos: [2]f32, comptime fmt: []const u8, args: anytype, options: TextOptions) [2]f32 {
    const font = options.font orelse &this.font;
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

pub fn end(this: *@This()) void {
    this.flush();
    this.transform_stack.shrinkRetainingCapacity(0);
}

pub fn textWriter(this: *@This(), options: TextWriter.Options) TextWriter {
    return TextWriter{
        .canvas = this,
        .options = options,
        .direction = 1,
        .current_pos = options.pos,
    };
}

pub const TextWriter = struct {
    canvas: *Canvas,
    options: Options,
    direction: f32,
    current_pos: [2]f32,
    size: [2]f32 = .{ 0, 0 },

    pub const Options = struct {
        pos: [2]f32 = .{ 0, 0 },
        color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        scale: f32 = 1,
    };

    pub fn addCharacter(this: *@This(), character: u21) void {
        if (character == '\n') {
            this.current_pos[1] += this.canvas.font.lineHeight * this.options.scale;
            this.current_pos[0] = this.options.pos[0];

            this.size = .{
                @max(this.current_pos[0] - this.options.pos[0], this.size[0]),
                @max(this.current_pos[1] - this.options.pos[1] + this.canvas.font.lineHeight * this.options.scale, this.size[1]),
            };
            return;
        }
        const glyph = this.canvas.font.glyphs.get(character) orelse {
            log.warn("No glyph found for character \"{}\"", .{std.fmt.fmtSliceHexLower(std.mem.asBytes(&character))});
            return;
        };

        const xadvance = (glyph.xadvance * this.options.scale);
        const offset = [2]f32{
            glyph.offset[0] * this.options.scale,
            glyph.offset[1] * this.options.scale,
        };

        const font_page = this.canvas.font_pages.get(glyph.page) orelse {
            log.warn("Unknown font page {} for glyph \"{}\"", .{ glyph.page, std.fmt.fmtSliceHexLower(std.mem.asBytes(&character)) });
            return;
        };

        this.canvas.rect(
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
            @max(this.current_pos[1] - this.options.pos[1] + this.canvas.font.lineHeight * this.options.scale, this.size[1]),
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

pub fn line(this: *@This(), pos1: [2]f32, pos2: [2]f32, options: struct {
    width: f32 = 1,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
}) void {
    this.vertices.ensureUnusedCapacity(this.allocator, 6) catch {
        this.flush();
    };
    if (this.current_texture != null) {
        this.flush();
        this.current_texture = null;
    }

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

    this.vertices.appendSliceAssumeCapacity(&.{
        .{
            .pos = back_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = fore_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = back_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },

        .{
            .pos = back_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },
        .{
            .pos = fore_left,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, -1 },
        },
        .{
            .pos = fore_right,
            .uv = .{ 0, 0 },
            .color = options.color,
            .shape = .triangle,
            .bary = .{ 0, 0, 1 },
        },
    });
}

pub fn flush(this: *@This()) void {
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.current_texture orelse this.blank_texture);
    defer {
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, 0);
    }

    gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
    defer gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    gl.bufferData(gl.ARRAY_BUFFER, @as(gl.Sizeiptr, @intCast(this.vertices.items.len * @sizeOf(Vertex))), this.vertices.items.ptr, gl.STREAM_DRAW);

    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "pos"))));
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "uv"))));
    gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "color"))));
    gl.enableVertexAttribArray(0);
    gl.enableVertexAttribArray(1);
    gl.enableVertexAttribArray(2);

    gl.useProgram(this.program);
    gl.drawArrays(gl.TRIANGLES, 0, @as(gl.Sizei, @intCast(this.vertices.items.len)));

    this.vertices.shrinkRetainingCapacity(0);
    this.current_texture = null;
}

const UniformLocations = struct {
    projection: c_int,
    texture: c_int,
};

const FontPage = struct {
    texture: gl.Uint,
    size: [2]f32,
};

const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

const log = std.log.scoped(.Canvas);
const std = @import("std");
const gl = seizer.gl;
const seizer = @import("seizer.zig");
const zigimg = @import("zigimg");
const geometry = @import("./geometry.zig");

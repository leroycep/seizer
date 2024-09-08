allocator: std.mem.Allocator,

fn_tables: *FnTables,

egl_display: EGL.Display,
egl_context: EGL.Context,

const GLes3v0Backend = @This();

const FnTables = struct {
    egl: EGL,
    egl_mesa_image_dma_buf_export: ?EGL.MESA.image_dma_buf_export,
    egl_khr_image_base: ?EGL.KHR.image_base,
    gl_binding: gl.Binding,
};

pub fn create(allocator: std.mem.Allocator, options: seizer.Platform.CreateGraphicsOptions) seizer.Platform.CreateGraphicsError!seizer.Graphics {
    _ = options;

    var library_prefixes = @"dynamic-library-utils".getLibrarySearchPaths(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LibraryLoadFailed,
    };
    defer library_prefixes.arena.deinit();

    // allocate a fixed memory location for fn_tables
    const fn_tables = try allocator.create(FnTables);
    errdefer allocator.destroy(fn_tables);

    fn_tables.egl = EGL.loadUsingPrefixes(library_prefixes.paths.items) catch |err| {
        std.log.warn("Failed to load EGL: {}", .{err});
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LibraryLoadFailed,
        }
    };

    var egl_display = fn_tables.egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.InitializationFailed;
    };
    _ = egl_display.initialize() catch return error.InitializationFailed;
    errdefer egl_display.terminate();

    fn_tables.egl_mesa_image_dma_buf_export = EGL.loadExtension(EGL.MESA.image_dma_buf_export, fn_tables.egl.functions) catch |err| switch (err) {
        else => return error.LibraryLoadFailed,
    };
    fn_tables.egl_khr_image_base = EGL.loadExtension(EGL.KHR.image_base, fn_tables.egl.functions) catch |err| switch (err) {
        else => return error.LibraryLoadFailed,
    };

    // create egl_context
    var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
        @intFromEnum(EGL.Attrib.red_size),        8,
        @intFromEnum(EGL.Attrib.blue_size),       8,
        @intFromEnum(EGL.Attrib.green_size),      8,
        @intFromEnum(EGL.Attrib.none),
    };
    const num_configs = egl_display.chooseConfig(&attrib_list, null) catch {
        return error.InitializationFailed;
    };

    if (num_configs == 0) {
        return error.InitializationFailed;
    }

    const configs_buffer = try allocator.alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer allocator.free(configs_buffer);

    const configs_len = egl_display.chooseConfig(&attrib_list, configs_buffer) catch return error.InitializationFailed;
    const configs = configs_buffer[0..configs_len];

    fn_tables.egl.bindAPI(.opengl_es) catch return error.InitializationFailed;
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 3,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = egl_display.createContext(configs[0], null, &context_attrib_list) catch return error.InitializationFailed;

    egl_display.makeCurrent(null, null, egl_context) catch return error.InitializationFailed;

    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);
    this.* = .{
        .allocator = allocator,
        .fn_tables = fn_tables,
        .egl_display = egl_display,
        .egl_context = egl_context,
    };

    // load opengl functions
    const loader = GlBindingLoader{ .egl = &this.fn_tables.egl };
    this.fn_tables.gl_binding.init(loader);
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);
    errdefer gl.makeBindingCurrent(null);

    if (builtin.mode == .Debug) checkError(@src());

    return this.graphics();
}

pub fn graphics(this: *@This()) seizer.Graphics {
    return .{
        .pointer = this,
        .interface = &INTERFACE,
    };
}

pub const INTERFACE = seizer.Graphics.Interface.getTypeErasedFunctions(@This(), .{
    .driver = .gles3v0,
    .destroy = destroy,
    .begin = _begin,
    .createShader = _createShader,
    .destroyShader = _destroyShader,
    .createTexture = _createTexture,
    .destroyTexture = _destroyTexture,
    .createPipeline = _createPipeline,
    .destroyPipeline = _destroyPipeline,
    .createBuffer = _createBuffer,
    .destroyBuffer = _destroyBuffer,
    .releaseRenderBuffer = _releaseRenderBuffer,
});

fn destroy(this: *@This()) void {
    this.egl_display.terminate();
    this.allocator.destroy(this.fn_tables);
    this.allocator.destroy(this);
}

fn _begin(this: *@This(), options: seizer.Graphics.BeginOptions) seizer.Graphics.BeginError!seizer.Graphics.CommandBuffer {
    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err| switch (err) {
        error.BadMatch => @panic("read/draw surface not set, should not get error.BadMatch"),
        error.BadAccess => return error.InUseOnOtherThread,
        error.BadContext => @panic("context destroyed before gles3v0 called?!"),
        error.BadNativeWindow => @panic("Not relying on EGL for windowing, this error should not happen"),
        error.BadCurrentSurface => @panic("Unflushed commands in previous context and the target surface is no longer valid"),
        error.BadAlloc => return error.OutOfMemory,
        error.NotInitialized => @panic("egl_display is not initialized"),
        error.BadDisplay => @panic("egl_display is invalid"),
        else => |e| std.debug.panic("unexpected error: {}", .{e}),
    };
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);
    if (builtin.mode == .Debug) checkError(@src());

    gl.viewport(0, 0, @intCast(options.size[0]), @intCast(options.size[1]));
    if (builtin.mode == .Debug) checkError(@src());

    const render_buffer = try RenderBuffer.create(this.allocator, options.size, this);
    errdefer render_buffer.destroy();
    if (builtin.mode == .Debug) checkError(@src());

    var clear_mask: gl.Bitfield = 0;
    if (options.clear_color) |clear_color| {
        gl.clearColor(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
        clear_mask |= gl.COLOR_BUFFER_BIT;
    }
    gl.clear(clear_mask);
    if (builtin.mode == .Debug) checkError(@src());

    const command_buffer = try CommandBuffer.create(this.allocator, render_buffer);

    return command_buffer.command_buffer();
}

const Shader = struct {
    gl_shader: gl.Uint,
};

fn _createShader(this: *@This(), options: seizer.Graphics.Shader.CreateOptions) seizer.Graphics.Shader.CreateError!*seizer.Graphics.Shader {
    const shader = try this.allocator.create(Shader);
    errdefer this.allocator.destroy(shader);

    const gl_shader = gl.createShader(switch (options.target) {
        .vertex => gl.VERTEX_SHADER,
        .fragment => gl.FRAGMENT_SHADER,
    });
    errdefer gl.deleteShader(gl_shader);

    switch (options.source) {
        .glsl => |glsl| {
            gl.shaderSource(gl_shader, 1, &[_][*:0]const u8{glsl.ptr}, &[_]c_int{@intCast(glsl.len)});
            gl.compileShader(gl_shader);
        },
        .spirv => {
            // TODO: Check for SPIR-V extension?
            return error.UnsupportedFormat;
        },
    }

    var shader_status: gl.Int = undefined;
    gl.getShaderiv(gl_shader, gl.COMPILE_STATUS, &shader_status);

    if (shader_status != gl.TRUE) {
        var shader_log_len: gl.Sizei = undefined;
        gl.getShaderInfoLog(gl_shader, 0, &shader_log_len, null);

        if (this.allocator.alloc(u8, @intCast(shader_log_len))) |shader_log_buf| {
            defer this.allocator.free(shader_log_buf);
            gl.getShaderInfoLog(gl_shader, @intCast(shader_log_buf.len), &shader_log_len, shader_log_buf.ptr);
            std.log.warn("error compiling shader: {s}", .{shader_log_buf[0..@intCast(shader_log_len)]});
        } else |_| {
            std.log.warn("error compiling shader", .{});
        }
        return error.ShaderCompilationFailed;
    }

    shader.* = .{
        .gl_shader = gl_shader,
    };
    if (builtin.mode == .Debug) checkError(@src());

    return @ptrCast(shader);
}

fn _destroyShader(this: *@This(), shader_opaque: *seizer.Graphics.Shader) void {
    const shader: *Shader = @ptrCast(@alignCast(shader_opaque));
    gl.deleteShader(shader.gl_shader);

    if (builtin.mode == .Debug) checkError(@src());

    this.allocator.destroy(shader);
}

const Texture = struct {
    gl_texture: gl.Uint,
    size: [2]u32,
};

fn _createTexture(this: *@This(), image: zigimg.Image, options: seizer.Graphics.Texture.CreateOptions) seizer.Graphics.Texture.CreateError!*seizer.Graphics.Texture {
    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err| switch (err) {
        error.BadMatch => @panic("read/draw surface not set, should not get error.BadMatch"),
        error.BadAccess => return error.InUseOnOtherThread,
        error.BadContext => @panic("context destroyed before gles3v0 called?!"),
        error.BadNativeWindow => @panic("Not relying on EGL for windowing, this error should not happen"),
        error.BadCurrentSurface => @panic("Unflushed commands in previous context and the target surface is no longer valid"),
        error.BadAlloc => return error.OutOfMemory,
        error.NotInitialized => @panic("egl_display is not initialized"),
        error.BadDisplay => @panic("egl_display is invalid"),
        else => |e| std.debug.panic("unexpected error: {}", .{e}),
    };
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    var gl_texture: gl.Uint = undefined;
    gl.genTextures(1, &gl_texture);
    if (gl_texture == 0) {
        return error.OutOfMemory;
    }

    const texture = try this.allocator.create(Texture);
    errdefer this.allocator.destroy(texture);

    gl.bindTexture(gl.TEXTURE_2D, gl_texture);
    defer gl.bindTexture(gl.TEXTURE_2D, 0);

    switch (image.pixels) {
        .rgba32 => |rgba32| gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(image.width), @intCast(image.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, rgba32.ptr),
        .grayscale8 => |grayscale8| gl.texImage2D(gl.TEXTURE_2D, 0, gl.ALPHA, @intCast(image.width), @intCast(image.width), 0, gl.ALPHA, gl.UNSIGNED_BYTE, std.mem.sliceAsBytes(grayscale8).ptr),
        else => return error.UnsupportedFormat,
    }

    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, switch (options.wrap[0]) {
        .clamp_to_edge => gl.CLAMP_TO_EDGE,
        .repeat => gl.REPEAT,
    });
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, switch (options.wrap[1]) {
        .clamp_to_edge => gl.CLAMP_TO_EDGE,
        .repeat => gl.REPEAT,
    });
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, switch (options.min_filter) {
        .nearest => gl.NEAREST,
        .linear => gl.LINEAR,
    });
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, switch (options.mag_filter) {
        .nearest => gl.NEAREST,
        .linear => gl.LINEAR,
    });

    texture.* = .{
        .gl_texture = gl_texture,
        .size = .{
            @intCast(image.width),
            @intCast(image.height),
        },
    };

    if (builtin.mode == .Debug) checkError(@src());

    return @ptrCast(texture);
}

fn _destroyTexture(this: *@This(), texture_opaque: *seizer.Graphics.Texture) void {
    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err|
        std.log.warn("unexpected make egl_context current error: {}", .{err});
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    if (builtin.mode == .Debug) checkError(@src());

    const texture: *Texture = @ptrCast(@alignCast(texture_opaque));
    gl.deleteTextures(1, &texture.gl_texture);

    this.allocator.destroy(texture);
}

const Pipeline = struct {
    program: gl.Uint,
    blend: ?seizer.Graphics.Pipeline.Blend,
    primitive: seizer.Graphics.Pipeline.Primitive,
    vertex_layout: []const seizer.Graphics.Pipeline.VertexAttribute,
};

fn _createPipeline(this: *@This(), options: seizer.Graphics.Pipeline.CreateOptions) seizer.Graphics.Pipeline.CreateError!*seizer.Graphics.Pipeline {
    const pipeline = try this.allocator.create(Pipeline);
    errdefer this.allocator.destroy(pipeline);

    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err| switch (err) {
        error.BadMatch => @panic("read/draw surface not set, should not get error.BadMatch"),
        error.BadAccess => return error.InUseOnOtherThread,
        error.BadContext => @panic("context destroyed before gles3v0 called?!"),
        error.BadNativeWindow => @panic("Not relying on EGL for windowing, this error should not happen"),
        error.BadCurrentSurface => @panic("Unflushed commands in previous context and the target surface is no longer valid"),
        error.BadAlloc => return error.OutOfMemory,
        error.NotInitialized => @panic("egl_display is not initialized"),
        error.BadDisplay => @panic("egl_display is invalid"),
        else => |e| std.debug.panic("unexpected error: {}", .{e}),
    };
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    if (builtin.mode == .Debug) checkError(@src());

    const vertex_shader: *Shader = @ptrCast(@alignCast(options.vertex_shader));
    const fragment_shader: *Shader = @ptrCast(@alignCast(options.fragment_shader));

    const program = gl.createProgram();
    errdefer gl.deleteProgram(program);

    gl.attachShader(program, vertex_shader.gl_shader);
    gl.attachShader(program, fragment_shader.gl_shader);
    defer {
        gl.detachShader(program, vertex_shader.gl_shader);
        gl.detachShader(program, fragment_shader.gl_shader);
    }

    gl.linkProgram(program);

    var program_status: gl.Int = undefined;
    gl.getProgramiv(program, gl.LINK_STATUS, &program_status);

    if (program_status != gl.TRUE) {
        var program_log: [1024:0]u8 = undefined;
        var program_log_len: gl.Sizei = undefined;
        gl.getProgramInfoLog(program, program_log.len, &program_log_len, &program_log);
        std.log.warn("{s}:{} error linking shader program: {s}\n", .{ @src().file, @src().line, program_log });
        return error.ShaderLinkingFailed;
    }

    const vertex_layout = try this.allocator.dupe(seizer.Graphics.Pipeline.VertexAttribute, options.vertex_layout);
    errdefer this.allocator.free(vertex_layout);

    pipeline.* = .{
        .program = program,
        .blend = options.blend,
        .primitive = options.primitive_type,
        .vertex_layout = vertex_layout,
    };

    if (builtin.mode == .Debug) checkError(@src());

    return @ptrCast(pipeline);
}

fn _destroyPipeline(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline) void {
    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err|
        std.log.warn("unexpected make egl_context current error: {}", .{err});
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    if (builtin.mode == .Debug) checkError(@src());

    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
    gl.deleteProgram(pipeline.program);

    this.allocator.free(pipeline.vertex_layout);

    this.allocator.destroy(pipeline);
}

fn _releaseRenderBuffer(this: *@This(), render_buffer_opaque: seizer.Graphics.RenderBuffer) void {
    _ = this;
    _ = render_buffer_opaque;
}

const Buffer = struct {
    gl_buffer: gl.Uint,
};

fn _createBuffer(this: *@This(), options: seizer.Graphics.Buffer.CreateOptions) seizer.Graphics.Buffer.CreateError!*seizer.Graphics.Buffer {
    _ = options;

    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err|
        std.log.warn("unexpected make egl_context current error: {}", .{err});
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    if (builtin.mode == .Debug) checkError(@src());

    const buffer = try this.allocator.create(Buffer);
    errdefer this.allocator.destroy(buffer);

    gl.genBuffers(1, &buffer.gl_buffer);
    errdefer gl.deleteBuffers(1, &buffer.gl_buffer);

    if (builtin.mode == .Debug) checkError(@src());

    return @ptrCast(buffer);
}

fn _destroyBuffer(this: *@This(), buffer_opaque: *seizer.Graphics.Buffer) void {
    this.egl_display.makeCurrent(null, null, this.egl_context) catch |err|
        std.log.warn("unexpected make egl_context current error: {}", .{err});
    gl.makeBindingCurrent(&this.fn_tables.gl_binding);

    if (builtin.mode == .Debug) checkError(@src());

    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));
    gl.deleteBuffers(1, &buffer.gl_buffer);

    this.allocator.destroy(buffer);
}

const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    current_pipeline: ?*Pipeline,
    render_buffer: *RenderBuffer,

    pub fn create(allocator: std.mem.Allocator, render_buffer: *RenderBuffer) !*@This() {
        const this = try allocator.create(@This());
        errdefer allocator.destroy(this);
        this.* = .{
            .allocator = allocator,
            .current_pipeline = null,
            .render_buffer = render_buffer,
        };
        return this;
    }

    pub fn command_buffer(this: *@This()) seizer.Graphics.CommandBuffer {
        return .{
            .pointer = this,
            .interface = &CommandBuffer.INTERFACE,
        };
    }

    pub const INTERFACE = seizer.Graphics.CommandBuffer.Interface.getTypeErasedFunctions(@This(), .{
        .bindPipeline = CommandBuffer._bindPipeline,
        .drawPrimitives = CommandBuffer._drawPrimitives,
        .uploadToBuffer = CommandBuffer._uploadToBuffer,
        .bindVertexBuffer = CommandBuffer._bindVertexBuffer,
        .uploadUniformMatrix4F32 = CommandBuffer._uploadUniformMatrix4F32,
        .uploadUniformTexture = CommandBuffer._uploadUniformTexture,
        .end = CommandBuffer._end,
    });

    fn _bindPipeline(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline) void {
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
        gl.useProgram(pipeline.program);
        this.current_pipeline = pipeline;

        if (pipeline.blend) |blend| {
            gl.enable(gl.BLEND);
            gl.blendFuncSeparate(
                switch (blend.src_color_factor) {
                    .one => gl.ONE,
                    .zero => gl.ZERO,
                    .src_alpha => gl.SRC_ALPHA,
                    .one_minus_src_alpha => gl.ONE_MINUS_SRC_ALPHA,
                },
                switch (blend.dst_color_factor) {
                    .one => gl.ONE,
                    .zero => gl.ZERO,
                    .src_alpha => gl.SRC_ALPHA,
                    .one_minus_src_alpha => gl.ONE_MINUS_SRC_ALPHA,
                },
                switch (blend.src_alpha_factor) {
                    .one => gl.ONE,
                    .zero => gl.ZERO,
                    .src_alpha => gl.SRC_ALPHA,
                    .one_minus_src_alpha => gl.ONE_MINUS_SRC_ALPHA,
                },
                switch (blend.dst_alpha_factor) {
                    .one => gl.ONE,
                    .zero => gl.ZERO,
                    .src_alpha => gl.SRC_ALPHA,
                    .one_minus_src_alpha => gl.ONE_MINUS_SRC_ALPHA,
                },
            );
        } else {
            gl.disable(gl.BLEND);
        }

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _drawPrimitives(this: *@This(), vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        _ = instance_count;
        _ = first_instance;
        std.debug.assert(this.current_pipeline != null);
        const pipeline = this.current_pipeline.?;
        gl.drawArrays(
            switch (pipeline.primitive) {
                .triangle => gl.TRIANGLES,
            },
            @intCast(first_vertex),
            @intCast(vertex_count),
        );

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _uploadToBuffer(this: *@This(), buffer_opaque: *seizer.Graphics.Buffer, data: []const u8) void {
        _ = this;
        const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));
        gl.bindBuffer(gl.COPY_WRITE_BUFFER, buffer.gl_buffer);
        defer gl.bindBuffer(gl.COPY_WRITE_BUFFER, 0);
        gl.bufferData(gl.COPY_WRITE_BUFFER, @intCast(data.len), data.ptr, gl.STREAM_DRAW);

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _bindVertexBuffer(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, vertex_buffer_opaque: *seizer.Graphics.Buffer) void {
        _ = this;
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
        const vertex_buffer: *Buffer = @ptrCast(@alignCast(vertex_buffer_opaque));

        gl.bindBuffer(gl.ARRAY_BUFFER, vertex_buffer.gl_buffer);

        for (pipeline.vertex_layout) |attrib| {
            gl.enableVertexAttribArray(attrib.attribute_index);
            gl.vertexAttribPointer(
                @intCast(attrib.attribute_index),
                @intCast(attrib.len),
                switch (attrib.type) {
                    .f32 => gl.FLOAT,
                    .u8 => gl.UNSIGNED_BYTE,
                },
                switch (attrib.normalized) {
                    true => gl.TRUE,
                    false => gl.FALSE,
                },
                @intCast(attrib.stride),
                @ptrFromInt(attrib.offset),
            );
        }

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _uploadUniformMatrix4F32(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, binding: u32, matrix: [4][4]f32) void {
        _ = this;
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

        gl.useProgram(pipeline.program);
        gl.uniformMatrix4fv(@intCast(binding), 1, gl.FALSE, &matrix[0][0]);

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _uploadUniformTexture(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, binding: u32, texture_opaque_opt: ?*seizer.Graphics.Texture) void {
        _ = this;
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

        gl.useProgram(pipeline.program);
        gl.activeTexture(gl.TEXTURE0);
        if (texture_opaque_opt) |texture_opaque| {
            const texture: *Texture = @ptrCast(@alignCast(texture_opaque));
            gl.bindTexture(gl.TEXTURE_2D, texture.gl_texture);
        } else {
            gl.bindTexture(gl.TEXTURE_2D, 0);
        }
        gl.uniform1i(@intCast(binding), 0);

        if (builtin.mode == .Debug) checkError(@src());
    }

    fn _end(this: *@This()) seizer.Graphics.CommandBuffer.EndError!seizer.Graphics.RenderBuffer {
        if (builtin.mode == .Debug) checkError(@src());
        gl.flush();
        if (builtin.mode == .Debug) checkError(@src());
        const render_buffer = this.render_buffer.render_buffer();
        this.allocator.destroy(this);
        return render_buffer;
    }
};

const RenderBuffer = struct {
    allocator: std.mem.Allocator,
    reference_count: u32,
    backend: *GLes3v0Backend,

    size: [2]u32,
    gl_render_buffers: [1]gl.Uint = .{0},
    gl_framebuffer_objects: [1]gl.Uint = .{0},
    egl_image: EGL.KHR.image_base.Image,

    pub fn create(allocator: std.mem.Allocator, size: [2]u32, backend: *GLes3v0Backend) !*@This() {
        const this = try allocator.create(@This());
        this.* = .{
            .allocator = allocator,
            .reference_count = 1,
            .backend = backend,
            .egl_image = undefined,
            .size = size,
        };
        errdefer this._release();

        gl.genRenderbuffers(this.gl_render_buffers.len, &this.gl_render_buffers);
        gl.genFramebuffers(this.gl_framebuffer_objects.len, &this.gl_framebuffer_objects);

        gl.bindRenderbuffer(gl.RENDERBUFFER, this.gl_render_buffers[0]);
        gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGB8, @intCast(size[0]), @intCast(size[1]));

        gl.bindFramebuffer(gl.FRAMEBUFFER, this.gl_framebuffer_objects[0]);
        gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, this.gl_render_buffers[0]);

        this.egl_image = this.backend.fn_tables.egl_khr_image_base.?.createImage(
            this.backend.egl_display,
            this.backend.egl_context,
            .gl_renderbuffer,
            @ptrFromInt(@as(usize, @intCast(this.gl_render_buffers[0]))),
            null,
        ) catch |err| switch (err) {
            error.BadDisplay,
            error.BadContext,
            error.BadParameter,
            error.BadMatch,
            error.BadAccess,
            => |e| std.debug.panic("unexpected error: {}", .{e}),
            error.BadAlloc => return error.OutOfMemory,
            else => |e| std.debug.panic("unexpected error: {}", .{e}),
        };

        if (builtin.mode == .Debug) checkError(@src());

        return this;
    }

    pub fn render_buffer(this: *@This()) seizer.Graphics.RenderBuffer {
        return .{
            .pointer = this,
            .interface = &RenderBuffer.INTERFACE,
        };
    }

    pub const INTERFACE = seizer.Graphics.RenderBuffer.Interface.getTypeErasedFunctions(@This(), .{
        .release = RenderBuffer._release,
        .getSize = RenderBuffer._getSize,
        .getDmaBufFormat = RenderBuffer._getDmaBufFormat,
        .getDmaBufPlanes = RenderBuffer._getDmaBufPlanes,
    });

    pub fn _release(this: *@This()) void {
        this.reference_count -= 1;
        if (this.reference_count == 0) {
            this.destroy();
        }
    }

    fn _getSize(this: *@This()) [2]u32 {
        return this.size;
    }

    fn _getDmaBufFormat(this: *@This()) seizer.Graphics.RenderBuffer.DmaBufFormat {
        const result = this.backend.fn_tables.egl_mesa_image_dma_buf_export.?.queryImage(this.backend.egl_display, this.egl_image) catch |err| std.debug.panic("too lazy rn: {}", .{err});
        return seizer.Graphics.RenderBuffer.DmaBufFormat{
            .fourcc = @enumFromInt(result.fourcc),
            .plane_count = @intCast(result.num_planes),
            .modifiers = result.modifiers,
        };
    }

    fn _getDmaBufPlanes(this: *@This(), buf: []seizer.Graphics.RenderBuffer.DmaBufPlane) []seizer.Graphics.RenderBuffer.DmaBufPlane {
        const image_properties = this.backend.fn_tables.egl_mesa_image_dma_buf_export.?.queryImage(this.backend.egl_display, this.egl_image) catch |err| std.debug.panic("too lazy rn: {}", .{err});
        std.debug.assert(buf.len >= @as(usize, @intCast(image_properties.num_planes)));

        const slice = buf[0..@intCast(image_properties.num_planes)];

        var fds_buf: [10]std.posix.fd_t = undefined;
        var strides_buf: [10]EGL.Int = undefined;
        var offsets_buf: [10]EGL.Int = undefined;
        this.backend.fn_tables.egl_mesa_image_dma_buf_export.?.exportImage(
            this.backend.egl_display,
            this.egl_image,
            fds_buf[0..slice.len],
            strides_buf[0..slice.len],
            offsets_buf[0..slice.len],
        ) catch |err| std.debug.panic("too lazy rn: {}", .{err});
        for (slice, 0.., fds_buf[0..slice.len], strides_buf[0..slice.len], offsets_buf[0..slice.len]) |*plane, i, fd, stride, offset| {
            plane.* = .{
                .fd = fd,
                .index = @intCast(i),
                .stride = @intCast(stride),
                .offset = @intCast(offset),
            };
        }

        return slice;
    }

    pub fn bind(this: *@This()) void {
        gl.bindFramebuffer(gl.FRAMEBUFFER, this.gl_framebuffer_objects[0]);
        gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, this.gl_render_buffers[0]);

        if (builtin.mode == .Debug) checkError(@src());
    }

    pub fn destroy(this: *@This()) void {
        this.backend.fn_tables.egl_khr_image_base.?.destroyImage(this.backend.egl_display, this.egl_image) catch {};
        gl.deleteRenderbuffers(this.gl_render_buffers.len, &this.gl_render_buffers);
        gl.deleteFramebuffers(this.gl_framebuffer_objects.len, &this.gl_framebuffer_objects);
        this.allocator.destroy(this);
    }

    pub fn acquire(this: *@This()) void {
        this.reference_count += 1;
    }
};

pub const GlBindingLoader = struct {
    egl: *const EGL,
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(this: @This(), command_name: [:0]const u8) ?AnyCFnPtr {
        return this.egl.functions.eglGetProcAddress(command_name);
    }

    pub fn extensionSupported(this: @This(), extension_name: [:0]const u8) bool {
        _ = this;
        _ = extension_name;
        return true;
    }
};

/// Custom functions to make loading easier
pub fn shaderSource(shader: gl.Uint, source: []const u8) void {
    gl.shaderSource(shader, 1, &source.ptr, &@as(c_int, @intCast(source.len)));
}

pub fn compileShader(allocator: std.mem.Allocator, vertex_source: [:0]const u8, fragment_source: [:0]const u8) !gl.Uint {
    const vertex_shader = try compilerShaderPart(allocator, gl.VERTEX_SHADER, vertex_source);
    defer gl.deleteShader(vertex_shader);

    const fragment_shader = try compilerShaderPart(allocator, gl.FRAGMENT_SHADER, fragment_source);
    defer gl.deleteShader(fragment_shader);

    const program = gl.createProgram();
    if (program == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteProgram(program);

    gl.attachShader(program, vertex_shader);
    defer gl.detachShader(program, vertex_shader);

    gl.attachShader(program, fragment_shader);
    defer gl.detachShader(program, fragment_shader);

    gl.linkProgram(program);

    var link_status: gl.Int = undefined;
    gl.getProgramiv(program, gl.LINK_STATUS, &link_status);

    if (link_status != gl.TRUE) {
        var info_log_length: gl.Int = undefined;
        gl.getProgramiv(program, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @as(usize, @intCast(info_log_length)));
        defer allocator.free(info_log);

        gl.getProgramInfoLog(program, @as(c_int, @intCast(info_log.len)), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{s}", .{info_log});

        return error.InvalidShader;
    }

    return program;
}

pub fn compilerShaderPart(allocator: std.mem.Allocator, shader_type: gl.Enum, source: [:0]const u8) !gl.Uint {
    const shader = gl.createShader(shader_type);
    if (shader == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteShader(shader);

    var sources = [_][*c]const u8{source.ptr};
    var lengths = [_]gl.Int{@as(gl.Int, @intCast(source.len))};

    gl.shaderSource(shader, 1, &sources, &lengths);

    gl.compileShader(shader);

    var compile_status: gl.Int = undefined;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &compile_status);

    if (compile_status != gl.TRUE) {
        var info_log_length: gl.Int = undefined;
        gl.getShaderiv(shader, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @as(usize, @intCast(info_log_length)));
        defer allocator.free(info_log);

        gl.getShaderInfoLog(shader, @as(c_int, @intCast(info_log.len)), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{s}", .{info_log});

        return error.InvalidShader;
    }

    return shader;
}

pub fn checkError(src: std.builtin.SourceLocation) void {
    switch (gl.getError()) {
        gl.NO_ERROR => return,
        gl.INVALID_ENUM => std.log.warn("{s}:{} gl.INVALID_ENUM", .{ src.file, src.line }),
        gl.INVALID_VALUE => std.log.warn("{s}:{} gl.INVALID_VALUE", .{ src.file, src.line }),
        gl.INVALID_OPERATION => std.log.warn("{s}:{} gl.INVALID_OPERATION", .{ src.file, src.line }),
        gl.OUT_OF_MEMORY => std.log.warn("{s}:{} gl.OUT_OF_MEMORY", .{ src.file, src.line }),
        gl.INVALID_FRAMEBUFFER_OPERATION => std.log.warn("{s}:{} gl.INVALID_FRAMEBUFFER_OPERATION", .{ src.file, src.line }),
        else => |code| std.log.warn("{s}:{} {}", .{ src.file, src.line, code }),
    }
    std.debug.dumpCurrentStackTrace(@returnAddress());
}

const @"dynamic-library-utils" = @import("dynamic-library-utils");
const zigimg = @import("zigimg");
const EGL = @import("EGL");
const gl = @import("gl");
const seizer = @import("../../seizer.zig");
const std = @import("std");
const builtin = @import("builtin");

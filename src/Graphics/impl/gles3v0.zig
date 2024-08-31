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
        return error.GraphicsInitializationFailed;
    };
    _ = egl_display.initialize() catch return error.GraphicsInitializationFailed;
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
        return error.GraphicsInitializationFailed;
    };

    if (num_configs == 0) {
        return error.GraphicsInitializationFailed;
    }

    const configs_buffer = try allocator.alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer allocator.free(configs_buffer);

    const configs_len = egl_display.chooseConfig(&attrib_list, configs_buffer) catch return error.GraphicsInitializationFailed;
    const configs = configs_buffer[0..configs_len];

    fn_tables.egl.bindAPI(.opengl_es) catch return error.GraphicsInitializationFailed;
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 3,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = egl_display.createContext(configs[0], null, &context_attrib_list) catch return error.GraphicsInitializationFailed;

    egl_display.makeCurrent(null, null, egl_context) catch return error.GraphicsInitializationFailed;

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

    return this.graphics();
}

pub fn graphics(this: *@This()) seizer.Graphics {
    return .{
        .pointer = this,
        .interface = &INTERFACE,
    };
}

pub const INTERFACE = seizer.Graphics.Interface.getTypeErasedFunctions(@This(), .{
    .destroy = destroy,
    .begin = _begin,
    .createTexture = _createTexture,
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

    gl.viewport(0, 0, @intCast(options.size[0]), @intCast(options.size[1]));

    const render_buffer = try RenderBuffer.create(this.allocator, options.size, this);
    errdefer render_buffer.destroy();

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

fn _createTexture(this: *@This(), allocator: std.mem.Allocator, image: zigimg.Image, options: seizer.Graphics.CreateTextureOptions) seizer.Graphics.CreateTextureError!seizer.Graphics.Texture {
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

    const texture_pointer = try allocator.create(Texture);
    errdefer allocator.destroy(texture_pointer);

    gl.bindTexture(gl.TEXTURE_2D, gl_texture);
    defer gl.bindTexture(gl.TEXTURE_2D, 0);

    switch (image.pixels) {
        .rgba32 => |rgba32| gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(image.width), @intCast(image.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, rgba32.ptr),
        else => return error.UnsupportedFormat,
    }

    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intFromEnum(options.wrap[0]));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intFromEnum(options.wrap[1]));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intFromEnum(options.min_filter));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intFromEnum(options.mag_filter));

    texture_pointer.* = .{
        .allocator = allocator,
        .gl_texture = gl_texture,
        .size = .{
            @intCast(image.width),
            @intCast(image.height),
        },
    };

    return texture_pointer.texture();
}

const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    render_buffer: *RenderBuffer,

    pub fn create(allocator: std.mem.Allocator, render_buffer: *RenderBuffer) !*@This() {
        const this = try allocator.create(@This());
        errdefer allocator.destroy(this);
        this.* = .{
            .allocator = allocator,
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
        .end = CommandBuffer.end,
    });

    fn end(this: *@This()) seizer.Graphics.CommandBuffer.EndError!seizer.Graphics.RenderBuffer {
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
            .fourcc = @bitCast(result.fourcc),
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

const Texture = struct {
    allocator: std.mem.Allocator,
    gl_texture: gl.Uint,
    size: [2]u32,

    pub fn texture(this: *@This()) seizer.Graphics.Texture {
        return .{
            .pointer = this,
            .interface = &Texture.INTERFACE,
        };
    }

    pub const INTERFACE = seizer.Graphics.Texture.Interface.getTypeErasedFunctions(@This(), .{
        .release = Texture._release,
        .getSize = Texture._getSize,
    });

    fn _release(this: *@This()) void {
        // TODO: Reference counting
        this.allocator.destroy(this);
    }

    fn _getSize(this: *@This()) [2]u32 {
        return this.size;
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

// seizer.gl_utils.checkError(@src());
pub fn checkError(src: std.builtin.SourceLocation) void {
    switch (gl.getError()) {
        gl.NO_ERROR => {},
        gl.INVALID_ENUM => std.log.warn("{s}:{} gl.INVALID_ENUM", .{ src.file, src.line }),
        gl.INVALID_VALUE => std.log.warn("{s}:{} gl.INVALID_VALUE", .{ src.file, src.line }),
        gl.INVALID_OPERATION => std.log.warn("{s}:{} gl.INVALID_OPERATION", .{ src.file, src.line }),
        gl.OUT_OF_MEMORY => std.log.warn("{s}:{} gl.OUT_OF_MEMORY", .{ src.file, src.line }),
        gl.INVALID_FRAMEBUFFER_OPERATION => std.log.warn("{s}:{} gl.INVALID_FRAMEBUFFER_OPERATION", .{ src.file, src.line }),
        else => |code| std.log.warn("{s}:{} {}", .{ src.file, src.line, code }),
    }
}

const @"dynamic-library-utils" = @import("dynamic-library-utils");
const zigimg = @import("zigimg");
const EGL = @import("EGL");
const gl = @import("gl");
const seizer = @import("../../seizer.zig");
const std = @import("std");
const builtin = @import("builtin");

dyn_lib: std.DynLib,
functions: Functions,

const EGL = @This();

pub fn loadUsingPrefixes(prefixes: []const []const u8) !@This() {
    const library_name = "libEGL.so";
    var dyn_lib = load_lib: for (prefixes) |prefix| {
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        @memcpy(path_buffer[0..prefix.len], prefix);
        path_buffer[prefix.len] = '/';
        @memcpy(path_buffer[prefix.len + 1 ..][0..library_name.len], library_name);
        const path = path_buffer[0 .. prefix.len + 1 + library_name.len];

        const lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        break :load_lib lib;
    } else {
        log.warn("could not load \"{s}\", searched paths:", .{library_name});
        for (prefixes) |prefix| {
            log.warn("\t{s}", .{prefix});
        }
        return error.NotFound;
    };

    const functions = try Functions.fromDynLib(&dyn_lib);
    return @This(){
        .dyn_lib = dyn_lib,
        .functions = functions,
    };
}

pub const Functions = struct {
    eglGetDisplay: *const fn (native_display_type: ?*anyopaque) ?*Display.Handle,
    eglGetError: *const fn () ErrorCode,
    eglBindAPI: *const fn (Api) Boolean,
    eglInitialize: *const fn (*Display.Handle, major: ?*Int, minor: ?*Int) Boolean,
    eglChooseConfig: *const fn (*Display.Handle, attrib_list: [*]Int, configs_out: ?[*]*Config.Handle, config_size: Int, num_config_out: *Int) Boolean,
    eglCreatePbufferSurface: *const fn (*Display.Handle, config: *Config.Handle, attrib_list: ?[*]const Int) ?*Surface.Handle,
    eglCreateWindowSurface: *const fn (*Display.Handle, config: *Config.Handle, NativeWindowType, attrib_list: ?[*]const Int) ?*Surface.Handle,
    eglCreateContext: *const fn (*Display.Handle, config: *Config.Handle, share_context: ?*Context, attrib_list: ?[*]const Int) ?*Context.Handle,
    eglMakeCurrent: *const fn (*Display.Handle, draw: ?*Surface.Handle, read: ?*Surface.Handle, ctx: ?*Context.Handle) Boolean,
    eglGetProcAddress: *const fn ([*:0]const u8) ?*align(@alignOf(fn () callconv(.C) void)) const anyopaque,
    eglSwapBuffers: *const fn (*Display.Handle, draw: *Surface.Handle) Boolean,
    eglGetConfigAttrib: *const fn (*Display.Handle, config: *Config.Handle, attribute: Attrib, value_out: *Int) Boolean,
    eglQueryString: *const fn (*Display.Handle, name: Display.QueryStringName) ?[*:0]const u8,
    eglTerminate: *const fn (*Display.Handle) Boolean,
    eglReleaseThread: *const fn () Boolean,
    eglDestroySurface: *const fn (*Display.Handle, *Surface.Handle) Boolean,
    eglQuerySurface: *const fn (*Display.Handle, *Surface.Handle, Attrib, value_out: *Int) Boolean,
    eglCreateImage: *const fn (*Display.Handle, *Context.Handle, CreateImageTarget, ?*anyopaque, ?[*]const Int) ?*Image.Handle,
    eglDestroyImage: *const fn (*Display.Handle, *Image.Handle) Boolean,

    pub fn fromDynLib(dyn_lib: *std.DynLib) !@This() {
        var this: @This() = undefined;

        const fields = std.meta.fields(@This());
        inline for (fields) |field| {
            @field(this, field.name) = dyn_lib.lookup(field.type, field.name) orelse {
                log.warn("function not found: \"{}\"", .{std.zig.fmtEscapes(field.name)});
                return error.FunctionNotFound;
            };
        }

        return this;
    }
};

pub const EXT = struct {
    pub const DeviceBase = struct {
        pub const DEVICE = 0x322C;
        pub const Device = opaque {};
        eglQueryDevicesEXT: *const fn (max_devices: Int, devices_out: [*]*Device, num_devices_out: *Int) Boolean,
        eglQueryDeviceStringEXT: *const fn (*Device, name: Int) ?[*:0]const u8,
        // typedef EGLBoolean (EGLAPIENTRYP PFNEGLQUERYDEVICEATTRIBEXTPROC) (EGLDeviceEXT device, EGLint attribute, EGLAttrib *value);
        // typedef EGLBoolean (EGLAPIENTRYP PFNEGLQUERYDISPLAYATTRIBEXTPROC) (EGLDisplay dpy, EGLint attribute, EGLAttrib *value);
    };
};

pub const MESA = struct {
    pub const image_dma_buf_export = struct {
        eglExportDMABUFImageQueryMESA: *const fn (*Display.Handle, *Image.Handle, fourcc: ?*c_int, num_planes: ?*c_int, modifiers: ?*u64) Boolean,
        eglExportDMABUFImageMESA: *const fn (*Display.Handle, *Image.Handle, fds: ?[*]c_int, strides: ?[*]Int, offsets: ?[*]Int) Boolean,

        pub const ImageQueryResult = struct {
            fourcc: c_int,
            num_planes: c_int,
            modifiers: u64,
        };
        pub fn queryImage(this: @This(), display: Display, image: Image) Error!ImageQueryResult {
            var result: ImageQueryResult = undefined;
            switch (this.eglExportDMABUFImageQueryMESA(
                display.ptr,
                image.ptr,
                &result.fourcc,
                &result.num_planes,
                &result.modifiers,
            )) {
                .true => {},
                .false => return display.egl.functions.eglGetError().toZigError(),
            }
            return result;
        }

        pub const ExportImageResult = struct {
            allocator: std.mem.Allocator,
            fourcc: c_int,
            num_planes: c_int,
            modifiers: u64,
            dmabuf_fds: []c_int,
            strides: []c_int,
            offsets: []c_int,

            pub fn deinit(this: @This()) void {
                for (this.dmabuf_fds) |fd| {
                    std.posix.close(fd);
                }
                this.allocator.free(this.dmabuf_fds);
                this.allocator.free(this.strides);
                this.allocator.free(this.offsets);
            }
        };
        pub fn exportImageAlloc(this: @This(), allocator: std.mem.Allocator, display: Display, image: Image) !ExportImageResult {
            var query_result: ImageQueryResult = undefined;
            switch (this.eglExportDMABUFImageQueryMESA(
                display.ptr,
                image.ptr,
                &query_result.fourcc,
                &query_result.num_planes,
                &query_result.modifiers,
            )) {
                .true => {},
                .false => return display.egl.functions.eglGetError().toZigError(),
            }

            const dmabuf_fds = try allocator.alloc(c_int, @intCast(query_result.num_planes));
            errdefer allocator.free(dmabuf_fds);
            const strides = try allocator.alloc(c_int, @intCast(query_result.num_planes));
            errdefer allocator.free(strides);
            const offsets = try allocator.alloc(c_int, @intCast(query_result.num_planes));
            errdefer allocator.free(offsets);

            switch (this.eglExportDMABUFImageMESA(
                display.ptr,
                image.ptr,
                dmabuf_fds.ptr,
                strides.ptr,
                offsets.ptr,
            )) {
                .true => {},
                .false => return display.egl.functions.eglGetError().toZigError(),
            }

            return .{
                .allocator = allocator,
                .fourcc = query_result.fourcc,
                .num_planes = query_result.num_planes,
                .modifiers = query_result.modifiers,
                .dmabuf_fds = dmabuf_fds,
                .strides = strides,
                .offsets = offsets,
            };
        }
    };
};

pub fn loadExtension(comptime Extension: type, functions: Functions) !Extension {
    var ext: Extension = undefined;

    const fields = std.meta.fields(Extension);
    inline for (fields) |field| {
        @field(ext, field.name) = @ptrCast(functions.eglGetProcAddress(field.name) orelse {
            log.warn("function not found: \"{}\"", .{std.zig.fmtEscapes(field.name)});
            return error.FunctionNotFound;
        });
    }

    return ext;
}

pub fn deinit(this: *@This()) void {
    _ = this.functions.eglReleaseThread();
    this.dyn_lib.close();
    this.* = undefined;
}

pub fn getDisplay(this: *const @This(), native_display_type: ?*anyopaque) ?Display {
    const ptr = this.functions.eglGetDisplay(native_display_type) orelse return null;
    return Display{
        .egl = this,
        .ptr = ptr,
    };
}

pub fn bindAPI(egl: *const @This(), api: Api) !void {
    switch (egl.functions.eglBindAPI(api)) {
        .true => {},
        .false => return egl.functions.eglGetError().toZigError(),
    }
}

pub const Int = i32;
pub const Boolean = enum(c_uint) {
    false = 0,
    true = 1,
};
pub const NativeWindowType = ?*opaque {};

pub const Display = struct {
    egl: *const EGL,
    ptr: *Handle,

    const Handle = opaque {};

    const Version = struct { major: Int, minor: Int };
    pub fn initialize(this: *const @This()) Error!Version {
        var version: Version = undefined;

        switch (this.egl.functions.eglInitialize(this.ptr, &version.major, &version.minor)) {
            .true => return version,
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn terminate(this: *const @This()) void {
        _ = this.egl.functions.eglTerminate(this.ptr);
    }

    pub fn destroySurface(this: *const @This(), surface: Surface) void {
        _ = this.egl.functions.eglDestroySurface(this.ptr, surface.ptr);
    }

    pub fn querySurface(this: *const @This(), surface: Surface, attribute: Attrib) Error!Int {
        var value: Int = undefined;
        switch (this.egl.functions.eglQuerySurface(this.ptr, surface.ptr, attribute, &value)) {
            .true => return value,
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn chooseConfig(this: *const @This(), attrib_list: [*:@intFromEnum(Attrib.none)]Int, configs_out: ?[]*Config.Handle) Error!usize {
        const configs_ptr = if (configs_out) |c| c.ptr else null;
        const configs_len = if (configs_out) |c| c.len else 0;
        var num_configs: Int = undefined;
        switch (this.egl.functions.eglChooseConfig(this.ptr, attrib_list, configs_ptr, @intCast(configs_len), &num_configs)) {
            .true => return @intCast(num_configs),
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn createPbufferSurface(this: *const @This(), config: *Config.Handle, attrib_list: ?[*:@intFromEnum(Attrib.none)]const Int) Error!Surface {
        const handle = this.egl.functions.eglCreatePbufferSurface(this.ptr, config, attrib_list) orelse {
            return this.egl.functions.eglGetError().toZigError();
        };
        return Surface{
            .egl = this.egl,
            .ptr = handle,
        };
    }

    pub fn createWindowSurface(this: *const @This(), config: *Config.Handle, window: NativeWindowType, attrib_list: ?[*:@intFromEnum(Attrib.none)]const Int) Error!Surface {
        const handle = this.egl.functions.eglCreateWindowSurface(this.ptr, config, window, attrib_list) orelse {
            return this.egl.functions.eglGetError().toZigError();
        };
        return Surface{
            .egl = this.egl,
            .ptr = handle,
        };
    }

    pub fn createContext(this: *const @This(), config: *Config.Handle, share_context: ?*Context, attrib_list: ?[*:@intFromEnum(Attrib.none)]const Int) Error!Context {
        const handle = this.egl.functions.eglCreateContext(this.ptr, config, share_context, attrib_list) orelse {
            return this.egl.functions.eglGetError().toZigError();
        };
        return Context{
            .egl = this.egl,
            .ptr = handle,
        };
    }

    pub fn makeCurrent(this: *const @This(), draw: ?Surface, read: ?Surface, ctx: Context) Error!void {
        switch (this.egl.functions.eglMakeCurrent(this.ptr, if (draw) |d| d.ptr else null, if (read) |r| r.ptr else null, ctx.ptr)) {
            .true => {},
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn swapBuffers(this: *const @This(), surface: Surface) Error!void {
        switch (this.egl.functions.eglSwapBuffers(this.ptr, surface.ptr)) {
            .true => {},
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn getConfigAttrib(this: *const @This(), config: Config, attrib: Attrib) Error!Int {
        var value: Int = undefined;
        switch (this.egl.functions.eglGetConfigAttrib(this.ptr, config.ptr, attrib, &value)) {
            .true => return value,
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub fn createImage(this: *const @This(), ctx: Context, target: CreateImageTarget, target_handle: ?*anyopaque, attrib_list: ?[*:@intFromEnum(Attrib.none)]Int) Error!Image {
        const image_handle = this.egl.functions.eglCreateImage(
            this.ptr,
            ctx.ptr,
            target,
            target_handle,
            attrib_list,
        ) orelse {
            return this.egl.functions.eglGetError().toZigError();
        };
        return Image{
            .egl = this.egl,
            .ptr = image_handle,
        };
    }

    pub fn destroyImage(this: @This(), image: Image) Error!void {
        const result = this.egl.functions.eglDestroyImage(
            this.ptr,
            image.ptr,
        );
        switch (result) {
            .true => {},
            .false => return this.egl.functions.eglGetError().toZigError(),
        }
    }

    pub const QueryStringName = enum(Int) {
        vendor = 0x3053,
        version = 0x3054,
        extensions = 0x3055,
        client_apis = 0x308D,
        _,
    };

    pub fn queryString(this: *const @This(), name: QueryStringName) Error![*:0]const u8 {
        if (this.egl.functions.eglQueryString(this.ptr, name)) |str_ptr| {
            return str_ptr;
        } else {
            return this.egl.functions.eglGetError().toZigError();
        }
    }
};
pub const Config = struct {
    egl: *const EGL,
    ptr: *Handle,

    pub const Handle = opaque {};
};
pub const Surface = struct {
    egl: *const EGL,
    ptr: *Handle,

    pub const Handle = opaque {};
};
pub const Context = struct {
    egl: *const EGL,
    ptr: *Handle,

    pub const Handle = opaque {};
};
pub const Image = struct {
    egl: *const EGL,
    ptr: *Handle,

    pub const Handle = opaque {};
};
pub const Attrib = enum(Int) {
    config_id = 0x3028,
    buffer_size = 0x3020,
    alpha_size = 0x3021,
    blue_size = 0x3022,
    green_size = 0x3023,
    red_size = 0x3024,
    level = 0x3029,
    max_pbuffer_height = 0x302A,
    max_pbuffer_pixels = 0x302B,
    max_pbuffer_width = 0x302C,
    native_renderable = 0x302D,
    none = 0x3038,
    surface_type = 0x3033,
    renderable_type = 0x3040,
    height = 0x3056,
    width = 0x3057,

    context_major_version = 0x3098,
    context_minor_version = 0x30FB,

    bad_device_ext = 0x322B,
    _,
};
pub const PBUFFER_BIT = 0x0001;
pub const WINDOW_BIT = 0x0004;
pub const OPENGL_ES2_BIT = 0x0004;
pub const RenderableType = packed struct(Int) {
    opengl_es: bool,
    openvg: bool,
    opengl_es2: bool,
    opengl: bool,
    _padding2: u2 = 0,
    opengl_es3: bool,
    _padding1: u25 = 0,
};

pub const Api = enum(c_uint) {
    opengl_es = 0x30A0,
    openvg = 0x30A1,
    opengl = 0x30A2,
};

pub const CreateImageTarget = enum(c_uint) {
    gl_renderbuffer = 0x30B9,
    _,
};

pub const ErrorCode = enum(Int) {
    success = 0x3000,
    not_initialized = 0x3001,
    bad_access = 0x3002,
    bad_alloc = 0x3003,
    bad_attribute = 0x3004,
    bad_config = 0x3005,
    bad_context = 0x3006,
    bad_current_surface = 0x3007,
    bad_display = 0x3008,
    bad_match = 0x3009,
    bad_native_pixmap = 0x300A,
    bad_native_window = 0x300B,
    bad_parameter = 0x300C,
    bad_surface = 0x300D,
    non_conformant_config = 0x3051,
    _,

    pub fn toZigError(this: @This()) Error {
        switch (this) {
            .success => unreachable,
            .not_initialized => return Error.NotInitialized,
            .bad_access => return Error.BadAccess,
            .bad_alloc => return Error.BadAlloc,
            .bad_attribute => return Error.BadAttribute,
            .bad_config => return Error.BadConfig,
            .bad_context => return Error.BadContext,
            .bad_current_surface => return Error.BadCurrentSurface,
            .bad_display => return Error.BadDisplay,
            .bad_match => return Error.BadMatch,
            .bad_native_pixmap => return Error.BadNativePixmap,
            .bad_native_window => return Error.BadNativeWindow,
            .bad_parameter => return Error.BadParameter,
            .bad_surface => return Error.BadSurface,
            .non_conformant_config => return Error.NonConformantConfig,
            else => unreachable,
        }
    }
};

pub const Error = error{
    NotInitialized,
    BadAccess,
    BadAlloc,
    BadAttribute,
    BadConfig,
    BadContext,
    BadCurrentSurface,
    BadDisplay,
    BadMatch,
    BadNativePixmap,
    BadNativeWindow,
    BadParameter,
    BadSurface,
    NonConformantConfig,
};

const log = std.log.scoped(.EGL);

const std = @import("std");

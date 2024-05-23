pub const BACKEND = seizer.backend.Backend{
    .name = "wasm",
    .main = main,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var windows = std.AutoArrayHashMapUnmanaged(*Surface, Window){};
var next_window_id: u32 = 1;

var button_inputs = std.SegmentedList(seizer.Context.AddButtonInputOptions, 16){};
var button_bindings = std.AutoHashMapUnmanaged(seizer.Context.Binding, std.ArrayListUnmanaged(*seizer.Context.AddButtonInputOptions)){};

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    var seizer_context = seizer.Context{
        .gpa = gpa.allocator(),
        .backend_userdata = null,
        .backend = &BACKEND,
    };

    // Call root module's `init()` function
    root.init(&seizer_context) catch |err| {
        std.log.warn("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
}

pub fn createWindow(context: *seizer.Context, options: seizer.Context.CreateWindowOptions) anyerror!seizer.Window {
    _ = context;
    const size: [2]u32 = options.size orelse .{ 640, 480 };

    const surface = Surface.create_surface(size[0], size[1]) orelse return error.CreateSurface;

    const wasm_window = Window{
        .surface = surface,
        .on_render = options.on_render,
    };
    try windows.put(gpa.allocator(), surface, wasm_window);

    return wasm_window.window();
}

pub const Window = struct {
    surface: *Surface,
    on_render: ?*const fn (seizer.Window) anyerror!void,
    should_close: bool = false,

    pub const INTERFACE = seizer.Window.Interface{
        .getSize = getSize,
        .getFramebufferSize = getSize,
        .setShouldClose = setShouldClose,
    };

    pub fn window(this: @This()) seizer.Window {
        return seizer.Window{
            .pointer = this.surface,
            .interface = &INTERFACE,
        };
    }

    pub fn getSize(userdata: ?*anyopaque) [2]f32 {
        const this = windows.get(@ptrCast(userdata)).?;

        var size: [2]u32 = undefined;
        this.surface.surface_get_size(&size[0], &size[1]);

        return .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this = windows.getPtr(@ptrCast(userdata)).?;
        this.should_close = should_close;
    }
};

pub const Surface = opaque {
    pub extern "seizer" fn create_surface(width: u32, height: u32) ?*Surface;
    pub extern "seizer" fn surface_get_size(this: *@This(), width: ?*u32, height: ?*u32) void;
    pub extern "seizer" fn surface_make_gl_context_current(*Surface) void;
};

pub export fn _render() void {
    for (windows.values()) |window| {
        if (window.on_render) |render| {
            window.surface.surface_make_gl_context_current();
            render(window.window()) catch |err| {
                std.log.warn("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }
    }
}

pub export fn _key_event(surface: *Surface, key_code: u32, pressed: bool) void {
    const window = windows.getPtr(@ptrCast(surface)).?;
    _ = window;

    const binding = seizer.Context.Binding{ .keyboard = @enumFromInt(key_code) };
    if (button_bindings.get(binding)) |actions| {
        for (actions.items) |action| {
            action.on_event(pressed) catch |err| {
                std.log.warn("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
        }
    }
}

pub const gl = struct {
    pub const Byte = i8;
    pub const Ubyte = u8;
    pub const Short = c_short;
    pub const Ushort = c_ushort;
    pub const Int = c_int;
    pub const Uint = c_uint;
    pub const Int64 = i64;
    pub const Uint64 = u64;
    pub const Intptr = isize;
    pub const Half = c_ushort;
    pub const Float = f32;
    pub const Fixed = i32;
    pub const Boolean = u8;
    pub const Char = u8;
    pub const Bitfield = c_uint;
    pub const Enum = c_uint;
    pub const Sizei = c_int;
    pub const Sizeiptr = isize;
    pub const Clampf = f32;
    pub const Sync = ?*opaque {};

    pub const ZERO = 0x0;
    pub const ONE = 0x1;
    pub const FALSE = 0x0;
    pub const TRUE = 0x1;
    pub const NONE = 0x0;
    pub const POINTS = 0x0;
    pub const LINES = 0x1;
    pub const LINE_LOOP = 0x2;
    pub const LINE_STRIP = 0x3;
    pub const TRIANGLES = 0x4;
    pub const TRIANGLE_STRIP = 0x5;
    pub const TRIANGLE_FAN = 0x6;
    pub const DEPTH_BUFFER_BIT = 0x100;
    pub const STENCIL_BUFFER_BIT = 0x400;
    pub const COLOR_BUFFER_BIT = 0x4000;
    pub const NEAREST = 0x2600;
    pub const LINEAR = 0x2601;
    pub const CLAMP_TO_EDGE = 0x812F;
    pub const TEXTURE0 = 0x84C0;
    pub const REPEAT = 0x2901;
    pub const TEXTURE_2D = 0xDE1;
    pub const RGBA = 0x1908;
    pub const ARRAY_BUFFER = 0x8892;
    pub const UNSIGNED_BYTE = 0x1401;
    pub const TEXTURE_WRAP_S = 0x2802;
    pub const TEXTURE_WRAP_T = 0x2803;
    pub const TEXTURE_MAG_FILTER = 0x2800;
    pub const TEXTURE_MIN_FILTER = 0x2801;
    pub const FRAGMENT_SHADER = 0x8B30;
    pub const VERTEX_SHADER = 0x8B31;
    pub const COMPILE_STATUS = 0x8B81;
    pub const LINK_STATUS = 0x8B82;
    pub const INFO_LOG_LENGTH = 0x8B84;
    pub const FLOAT = 0x1406;
    pub const STREAM_DRAW = 0x88E0;
    pub const STREAM_READ = 0x88E1;
    pub const STREAM_COPY = 0x88E2;
    pub const STATIC_DRAW = 0x88E4;
    pub const STATIC_READ = 0x88E5;
    pub const STATIC_COPY = 0x88E6;
    pub const DYNAMIC_DRAW = 0x88E8;
    pub const DYNAMIC_READ = 0x88E9;
    pub const DYNAMIC_COPY = 0x88EA;
    pub const BLEND = 0xBE2;
    pub const SRC_ALPHA = 0x302;
    pub const ONE_MINUS_SRC_ALPHA = 0x303;
    pub const SCISSOR_TEST = 0xC11;
    pub const ALPHA = 0x1906;
    pub const DEPTH_TEST = 0xB71;

    pub extern "webgl2" fn clearColor(red: gl.Float, green: gl.Float, blue: gl.Float, alpha: gl.Float) void;
    pub extern "webgl2" fn clear(gl.Bitfield) void;
    pub extern "webgl2" fn useProgram(gl.Uint) void;
    pub extern "webgl2" fn activeTexture(gl.Enum) void;
    pub extern "webgl2" fn bindTexture(target: Enum, texture: Uint) void;
    pub extern "webgl2" fn bindVertexArray(array: Uint) void;
    pub extern "webgl2" fn genTextures(n: Sizei, textures: [*c]Uint) void;
    pub extern "webgl2" fn texImage2D(target: Enum, level: Int, internalformat: Int, width: Sizei, height: Sizei, border: Int, format: Enum, @"type": Enum, pixels: ?*const anyopaque) void;
    pub extern "webgl2" fn texParameteri(target: Enum, pname: Enum, param: Int) void;
    pub extern "webgl2" fn createProgram() Uint;
    pub extern "webgl2" fn createShader(@"type": Enum) Uint;
    pub extern "webgl2" fn shaderSource(shader: Uint, count: Sizei, string: [*c]const [*c]const Char, length: [*c]const Int) void;
    pub extern "webgl2" fn compileShader(shader: Uint) void;
    pub extern "webgl2" fn getShaderiv(shader: Uint, pname: Enum, params: [*c]Int) void;
    pub extern "webgl2" fn deleteShader(shader: Uint) void;
    pub extern "webgl2" fn getShaderInfoLog(shader: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) void;
    pub extern "webgl2" fn attachShader(program: Uint, shader: Uint) void;
    pub extern "webgl2" fn linkProgram(program: Uint) void;
    pub extern "webgl2" fn getProgramiv(program: Uint, pname: Enum, params: [*c]Int) void;
    pub extern "webgl2" fn detachShader(program: Uint, shader: Uint) void;
    pub extern "webgl2" fn deleteProgram(program: Uint) void;
    pub extern "webgl2" fn getProgramInfoLog(program: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) void;
    pub extern "webgl2" fn genBuffers(n: Sizei, buffers: [*c]Uint) void;
    pub extern "webgl2" fn genVertexArrays(n: Sizei, arrays: [*c]Uint) void;
    pub extern "webgl2" fn enableVertexAttribArray(index: Uint) void;
    pub extern "webgl2" fn bindBuffer(target: Enum, buffer: Uint) void;
    pub extern "webgl2" fn vertexAttribPointer(index: Uint, size: Int, @"type": Enum, normalized: Boolean, stride: Sizei, pointer: ?*const anyopaque) void;
    pub extern "webgl2" fn bufferData(target: Enum, size: Sizeiptr, data: ?*const anyopaque, usage: Enum) void;
    pub extern "webgl2" fn drawArrays(mode: Enum, first: Int, count: Sizei) void;
    pub extern "webgl2" fn enable(cap: Enum) void;
    pub extern "webgl2" fn disable(cap: Enum) void;
    pub extern "webgl2" fn blendFunc(sfactor: Enum, dfactor: Enum) void;
    pub extern "webgl2" fn deleteTextures(n: Sizei, textures: [*c]const Uint) void;
    pub extern "webgl2" fn getUniformLocation(program: Uint, name: [*:0]const Char) Int;
    pub extern "webgl2" fn scissor(x: Int, y: Int, width: Sizei, height: Sizei) void;
    pub extern "webgl2" fn deleteBuffers(n: Sizei, buffers: [*c]const Uint) void;
    pub extern "webgl2" fn uniform1i(location: Int, v0: Int) void;
    pub extern "webgl2" fn uniformMatrix4fv(location: Int, count: Sizei, transpose: Boolean, value: [*c]const Float) void;
};

pub fn addButtonInput(context: *seizer.Context, options: seizer.Context.AddButtonInputOptions) anyerror!void {
    _ = context;

    const options_owned = try button_inputs.addOne(gpa.allocator());
    options_owned.* = options;

    for (options.default_bindings) |button_code| {
        const gop = try button_bindings.getOrPut(gpa.allocator(), button_code);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(gpa.allocator(), options_owned);
    }
}

const seizer = @import("../seizer.zig");
const std = @import("std");

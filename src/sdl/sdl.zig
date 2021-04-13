const std = @import("std");
const c = @import("c.zig");
const App = @import("../seizer.zig").App;
const Event = @import("../event.zig").Event;
const Keycode = @import("../event.zig").Keycode;
const Scancode = @import("../event.zig").Scancode;
const MouseButton = @import("../event.zig").MouseButton;
const ControllerButtonEvent = @import("../event.zig").ControllerButtonEvent;
const builtin = @import("builtin");
// pub usingnamespace @import("./gl.zig");
pub const gl = @import("./gl_es_3v0.zig");
const Timer = std.time.Timer;

const Vec2i = @import("math").Vec2i;
const vec2i = @import("math").vec2i;

const sdllog = std.log.scoped(.PlatformNative);

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr = std.io.getStdErr().writer();
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    nosuspend stderr.print("[{s}][{s}] ", .{ std.meta.tagName(message_level), std.meta.tagName(scope) }) catch return;
    nosuspend stderr.print(format, args) catch return;
    _ = nosuspend stderr.write("\n") catch return;
}

pub const panic = builtin.default_panic;

pub const Context = struct {
    // Standard struct members
    alloc: *std.mem.Allocator,
    running: bool = true,

    // SDL backend specific
    window: *c.SDL_Window,
    gl_context: c.SDL_GLContext,

    pub fn setRelativeMouseMode(this: *@This(), val: bool) !void {
        const res = c.SDL_SetRelativeMouseMode(if (val) .SDL_TRUE else .SDL_FALSE);
        if (res != 0) {
            return logSDLErr(error.CouldntSetRelativeMouseMode);
        }
    }
};

/// _ parameter to get gl.load to not complain
fn get_proc_address(_: u8, proc: [:0]const u8) ?*c_void {
    return c.SDL_GL_GetProcAddress(proc);
}

var sdl_window: *c.SDL_Window = undefined;
var running = true;

pub fn getScreenSize() Vec2i {
    var size: Vec2i = undefined;
    c.SDL_GL_GetDrawableSize(sdl_window, &size.x, &size.y);
    return size;
}

pub fn run(comptime app: App) void {
    // Init SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMECONTROLLER) != 0) {
        logSDLErr(error.InitFailed);
    }
    defer c.SDL_Quit();

    sdlAssertZero(c.SDL_GL_SetAttribute(.SDL_GL_CONTEXT_MAJOR_VERSION, 3));
    sdlAssertZero(c.SDL_GL_SetAttribute(.SDL_GL_CONTEXT_MINOR_VERSION, 0));
    sdlAssertZero(c.SDL_GL_SetAttribute(.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_ES));
    sdlAssertZero(c.SDL_GL_SetAttribute(.SDL_GL_DOUBLEBUFFER, 1));

    const screenWidth = app.window.width orelse 640;
    const screenHeight = app.window.width orelse 480;

    sdl_window = c.SDL_CreateWindow(
        app.window.title,
        c.SDL_WINDOWPOS_UNDEFINED_MASK,
        c.SDL_WINDOWPOS_UNDEFINED_MASK,
        screenWidth,
        screenHeight,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        logSDLErr(error.CouldntCreateWindow);
    };
    defer c.SDL_DestroyWindow(sdl_window);

    const gl_context = c.SDL_GL_CreateContext(sdl_window);
    defer c.SDL_GL_DeleteContext(gl_context);
    c.SDL_ShowWindow(sdl_window);

    var ctx: u8 = 0; // bogus context variable to satisfy gl.load
    gl.load(ctx, get_proc_address) catch |err| std.debug.panic("Failed to load OpenGL: {}", .{err});

    // Setup opengl debug message callback
    // if (builtin.mode == .Debug) {
    //     gl.enable(gl.DEBUG_OUTPUT);
    //     gl.debugMessageCallback(MessageCallback, null);
    // }

    sdllog.info("application initialized", .{});

    nosuspend app.init() catch |err| std.debug.panic("Failed to initialze app: {}", .{err});
    defer app.deinit();

    // Timestep based on the Gaffer on Games post, "Fix Your Timestep"
    //    https://www.gafferongames.com/post/fix_your_timestep/
    const MAX_DELTA = app.maxDeltaSeconds;
    const TICK_DELTA = app.tickDeltaSeconds;
    var timer = Timer.start() catch |err| std.debug.panic("Failed to create timer: {}", .{err});
    var tickTime: f64 = 0.0;
    var accumulator: f64 = 0.0;

    while (running) {
        while (pollEvent()) |event| {
            app.event(event) catch |err| std.debug.panic("Failed to process event: {}", .{err});
        }

        var delta = @intToFloat(f64, timer.lap()) / std.time.ns_per_s; // Delta in seconds
        if (delta > MAX_DELTA) {
            delta = MAX_DELTA; // Try to avoid spiral of death when lag hits
        }

        accumulator += delta;

        while (accumulator >= TICK_DELTA) {
            app.update(tickTime, TICK_DELTA) catch |err| std.debug.panic("Failed to update app: {}", .{err});
            accumulator -= TICK_DELTA;
            tickTime += TICK_DELTA;
        }

        // Where the render is between two timesteps.
        // If we are halfway between frames (based on what's in the accumulator)
        // then alpha will be equal to 0.5
        const alpha = accumulator / TICK_DELTA;

        app.render(alpha) catch |err| std.debug.panic("Failed to render app: {}", .{err});
        c.SDL_GL_SwapWindow(sdl_window);
    }
}

pub fn quit() void {
    running = false;
}

pub const Error = error{
    InitFailed,
    CouldntCreateWindow,
    CouldntCreateRenderer,
    CouldntLoadBMP,
    CouldntCreateTexture,
    ImgInit,
    CouldntSetRelativeMouseMode,
};

pub fn logSDLErr(err: Error) noreturn {
    std.debug.panic("{}: {s}\n", .{ err, @as([*:0]const u8, c.SDL_GetError()) });
}

pub fn now() u64 {
    return std.time.milliTimestamp();
}

pub const FetchError = error{
    FileNotFound,
    OutOfMemory,
    Unknown,
};

pub fn fetch(allocator: *std.mem.Allocator, file_name: []const u8) FetchError![]const u8 {
    const cwd = std.fs.cwd();
    const contents = cwd.readFileAlloc(allocator, file_name, 50000) catch |err| switch (err) {
        error.FileNotFound, error.OutOfMemory => |e| return e,
        else => |e| return error.Unknown,
    };
    return contents;
}

pub fn randomBytes(slice: []u8) void {
    std.crypto.random.bytes(slice);
}

fn MessageCallback(source: gl.GLenum, msgtype: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, len: gl.GLsizei, msg: [*c]const gl.GLchar, userParam: ?*const c_void) callconv(.C) void {
    // const MessageCallback: gl.GLDEBUGPROC = {
    const msg_slice = msg[0..@intCast(usize, len)];
    const debug_msg_source = @intToEnum(OpenGL_DebugSource, source);
    const debug_msg_type = @intToEnum(OpenGL_DebugType, msgtype);
    switch (severity) {
        c.GL_DEBUG_SEVERITY_HIGH => sdllog.err("{} {} {}", .{ debug_msg_source, debug_msg_type, msg_slice }),
        c.GL_DEBUG_SEVERITY_MEDIUM => sdllog.warn("{} {} {}", .{ debug_msg_source, debug_msg_type, msg_slice }),
        c.GL_DEBUG_SEVERITY_LOW => sdllog.info("{} {} {}", .{ debug_msg_source, debug_msg_type, msg_slice }),
        c.GL_DEBUG_SEVERITY_NOTIFICATION => sdllog.notice("{} {} {}", .{ debug_msg_source, debug_msg_type, msg_slice }),
        else => unreachable,
    }
}

const OpenGL_DebugSource = enum(c.GLenum) {
    API = c.GL_DEBUG_SOURCE_API,
    ShaderCompiler = c.GL_DEBUG_SOURCE_SHADER_COMPILER,
    WindowSystem = c.GL_DEBUG_SOURCE_WINDOW_SYSTEM,
    ThirdParty = c.GL_DEBUG_SOURCE_THIRD_PARTY,
    Application = c.GL_DEBUG_SOURCE_APPLICATION,
    Other = c.GL_DEBUG_SOURCE_OTHER,
};

const OpenGL_DebugType = enum(c.GLenum) {
    Error = c.GL_DEBUG_TYPE_ERROR,
    DeprecatedBehavior = c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR,
    UndefinedBehavior = c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR,
    Perfomance = c.GL_DEBUG_TYPE_PERFORMANCE,
    Portability = c.GL_DEBUG_TYPE_PORTABILITY,
    Marker = c.GL_DEBUG_TYPE_MARKER,
    PushGroup = c.GL_DEBUG_TYPE_PUSH_GROUP,
    PopGroup = c.GL_DEBUG_TYPE_POP_GROUP,
    Other = c.GL_DEBUG_TYPE_OTHER,
};

pub fn sdlAssertZero(ret: c_int) void {
    if (ret == 0) return;
    std.debug.panic("sdl function returned an error: {s}\n", .{c.SDL_GetError()});
}

pub fn pollEvent() ?Event {
    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event) != 0) {
        return sdlToCommonEvent(event);
    } else {
        return null;
    }
}

pub fn sdlToCommonEvent(sdlEvent: c.SDL_Event) ?Event {
    switch (sdlEvent.@"type") {
        // Application events
        c.SDL_QUIT => return Event{ .Quit = {} },

        // Window events
        c.SDL_WINDOWEVENT => switch (sdlEvent.window.event) {
            c.SDL_WINDOWEVENT_RESIZED => return Event{ .ScreenResized = vec2i(sdlEvent.window.data1, sdlEvent.window.data2) },
            else => return null,
        },
        c.SDL_SYSWMEVENT => return null,

        // Keyboard events
        c.SDL_KEYDOWN => return Event{ .KeyDown = .{ .key = sdlToCommonKeycode(sdlEvent.key.keysym.sym), .scancode = sdlToCommonScancode(sdlEvent.key.keysym.scancode) } },
        c.SDL_KEYUP => return Event{ .KeyUp = .{ .key = sdlToCommonKeycode(sdlEvent.key.keysym.sym), .scancode = sdlToCommonScancode(sdlEvent.key.keysym.scancode) } },
        c.SDL_TEXTEDITING => return null,
        c.SDL_TEXTINPUT => return null,

        // Mouse events
        c.SDL_MOUSEMOTION => return Event{
            .MouseMotion = .{
                .pos = Vec2i.init(sdlEvent.motion.x, sdlEvent.motion.y),
                .rel = Vec2i.init(sdlEvent.motion.xrel, sdlEvent.motion.yrel),
                .buttons = 0,
            },
        },
        c.SDL_MOUSEBUTTONDOWN => return Event{
            .MouseButtonDown = .{
                .pos = Vec2i.init(sdlEvent.button.x, sdlEvent.button.y),
                .button = sdlToCommonButton(sdlEvent.button.button),
            },
        },
        c.SDL_MOUSEBUTTONUP => return Event{
            .MouseButtonUp = .{
                .pos = Vec2i.init(sdlEvent.button.x, sdlEvent.button.y),
                .button = sdlToCommonButton(sdlEvent.button.button),
            },
        },
        c.SDL_MOUSEWHEEL => return Event{
            .MouseWheel = Vec2i.init(
                sdlEvent.wheel.x,
                sdlEvent.wheel.y,
            ),
        },

        // Audio events
        c.SDL_AUDIODEVICEADDED => return null,
        c.SDL_AUDIODEVICEREMOVED => return null,

        // Controller events
        c.SDL_CONTROLLERAXISMOTION => {
            return Event{
                .ControllerAxis = .{
                    .timestamp = sdlEvent.caxis.timestamp,
                    .joystickID = sdlEvent.caxis.which,
                    .axis = sdlEvent.caxis.axis,
                    .value = sdlEvent.caxis.value,
                },
            };
        },

        c.SDL_CONTROLLERBUTTONUP, c.SDL_CONTROLLERBUTTONDOWN => {
            const button_event = ControllerButtonEvent{
                .timestamp = sdlEvent.cbutton.timestamp,
                .joystickID = sdlEvent.cbutton.which,
                .button = sdlEvent.cbutton.button,
                .pressed = if (sdlEvent.cbutton.state == c.SDL_PRESSED) true else false,
            };
            if (sdlEvent.@"type" == c.SDL_CONTROLLERBUTTONUP) {
                return Event{
                    .ControllerButtonUp = button_event,
                };
            } else {
                return Event{
                    .ControllerButtonDown = button_event,
                };
            }
        },

        c.SDL_CONTROLLERDEVICEADDED => {
            _ = c.SDL_GameControllerOpen(sdlEvent.cdevice.which);
            std.log.info("controller device added {}\n", .{sdlEvent.cdevice});
            return null;
        },

        c.SDL_CONTROLLERDEVICEREMOVED => {
            std.log.info("controller device removed {}\n", .{sdlEvent.cdevice});
            return null;
        },

        c.SDL_CONTROLLERDEVICEREMAPPED => {
            std.log.info("controller device remapped {}\n", .{sdlEvent.cdevice});
            return null;
        },

        else => std.debug.warn("unknown event {}\n", .{sdlEvent.@"type"}),
    }
    return null;
}

fn sdlToCommonButton(btn: u8) MouseButton {
    switch (btn) {
        c.SDL_BUTTON_LEFT => return .Left,
        c.SDL_BUTTON_MIDDLE => return .Middle,
        c.SDL_BUTTON_RIGHT => return .Right,
        c.SDL_BUTTON_X1 => return .X1,
        c.SDL_BUTTON_X2 => return .X2,
        else => std.debug.panic("unknown mouse button", .{}),
    }
}

fn sdlToCommonScancode(scn: c.SDL_Scancode) Scancode {
    switch (@enumToInt(scn)) {
        c.SDL_SCANCODE_UNKNOWN => return .UNKNOWN,
        c.SDL_SCANCODE_A => return .A,
        c.SDL_SCANCODE_B => return .B,
        c.SDL_SCANCODE_C => return .C,
        c.SDL_SCANCODE_D => return .D,
        c.SDL_SCANCODE_E => return .E,
        c.SDL_SCANCODE_F => return .F,
        c.SDL_SCANCODE_G => return .G,
        c.SDL_SCANCODE_H => return .H,
        c.SDL_SCANCODE_I => return .I,
        c.SDL_SCANCODE_J => return .J,
        c.SDL_SCANCODE_K => return .K,
        c.SDL_SCANCODE_L => return .L,
        c.SDL_SCANCODE_M => return .M,
        c.SDL_SCANCODE_N => return .N,
        c.SDL_SCANCODE_O => return .O,
        c.SDL_SCANCODE_P => return .P,
        c.SDL_SCANCODE_Q => return .Q,
        c.SDL_SCANCODE_R => return .R,
        c.SDL_SCANCODE_S => return .S,
        c.SDL_SCANCODE_T => return .T,
        c.SDL_SCANCODE_U => return .U,
        c.SDL_SCANCODE_V => return .V,
        c.SDL_SCANCODE_W => return .W,
        c.SDL_SCANCODE_X => return .X,
        c.SDL_SCANCODE_Y => return .Y,
        c.SDL_SCANCODE_Z => return .Z,
        c.SDL_SCANCODE_1 => return ._1,
        c.SDL_SCANCODE_2 => return ._2,
        c.SDL_SCANCODE_3 => return ._3,
        c.SDL_SCANCODE_4 => return ._4,
        c.SDL_SCANCODE_5 => return ._5,
        c.SDL_SCANCODE_6 => return ._6,
        c.SDL_SCANCODE_7 => return ._7,
        c.SDL_SCANCODE_8 => return ._8,
        c.SDL_SCANCODE_9 => return ._9,
        c.SDL_SCANCODE_0 => return ._0,
        c.SDL_SCANCODE_RETURN => return .RETURN,
        c.SDL_SCANCODE_ESCAPE => return .ESCAPE,
        c.SDL_SCANCODE_BACKSPACE => return .BACKSPACE,
        c.SDL_SCANCODE_TAB => return .TAB,
        c.SDL_SCANCODE_SPACE => return .SPACE,
        c.SDL_SCANCODE_MINUS => return .MINUS,
        c.SDL_SCANCODE_EQUALS => return .EQUALS,
        c.SDL_SCANCODE_LEFTBRACKET => return .LEFTBRACKET,
        c.SDL_SCANCODE_RIGHTBRACKET => return .RIGHTBRACKET,
        c.SDL_SCANCODE_BACKSLASH => return .BACKSLASH,
        c.SDL_SCANCODE_NONUSHASH => return .NONUSHASH,
        c.SDL_SCANCODE_SEMICOLON => return .SEMICOLON,
        c.SDL_SCANCODE_APOSTROPHE => return .APOSTROPHE,
        c.SDL_SCANCODE_GRAVE => return .GRAVE,
        c.SDL_SCANCODE_COMMA => return .COMMA,
        c.SDL_SCANCODE_PERIOD => return .PERIOD,
        c.SDL_SCANCODE_SLASH => return .SLASH,
        c.SDL_SCANCODE_CAPSLOCK => return .CAPSLOCK,
        c.SDL_SCANCODE_F1 => return .F1,
        c.SDL_SCANCODE_F2 => return .F2,
        c.SDL_SCANCODE_F3 => return .F3,
        c.SDL_SCANCODE_F4 => return .F4,
        c.SDL_SCANCODE_F5 => return .F5,
        c.SDL_SCANCODE_F6 => return .F6,
        c.SDL_SCANCODE_F7 => return .F7,
        c.SDL_SCANCODE_F8 => return .F8,
        c.SDL_SCANCODE_F9 => return .F9,
        c.SDL_SCANCODE_F10 => return .F10,
        c.SDL_SCANCODE_F11 => return .F11,
        c.SDL_SCANCODE_F12 => return .F12,
        c.SDL_SCANCODE_PRINTSCREEN => return .PRINTSCREEN,
        c.SDL_SCANCODE_SCROLLLOCK => return .SCROLLLOCK,
        c.SDL_SCANCODE_PAUSE => return .PAUSE,
        c.SDL_SCANCODE_INSERT => return .INSERT,
        c.SDL_SCANCODE_HOME => return .HOME,
        c.SDL_SCANCODE_PAGEUP => return .PAGEUP,
        c.SDL_SCANCODE_DELETE => return .DELETE,
        c.SDL_SCANCODE_END => return .END,
        c.SDL_SCANCODE_PAGEDOWN => return .PAGEDOWN,
        c.SDL_SCANCODE_RIGHT => return .RIGHT,
        c.SDL_SCANCODE_LEFT => return .LEFT,
        c.SDL_SCANCODE_DOWN => return .DOWN,
        c.SDL_SCANCODE_UP => return .UP,
        c.SDL_SCANCODE_NUMLOCKCLEAR => return .NUMLOCKCLEAR,
        c.SDL_SCANCODE_KP_DIVIDE => return .KP_DIVIDE,
        c.SDL_SCANCODE_KP_MULTIPLY => return .KP_MULTIPLY,
        c.SDL_SCANCODE_KP_MINUS => return .KP_MINUS,
        c.SDL_SCANCODE_KP_PLUS => return .KP_PLUS,
        c.SDL_SCANCODE_KP_ENTER => return .KP_ENTER,
        c.SDL_SCANCODE_KP_1 => return .KP_1,
        c.SDL_SCANCODE_KP_2 => return .KP_2,
        c.SDL_SCANCODE_KP_3 => return .KP_3,
        c.SDL_SCANCODE_KP_4 => return .KP_4,
        c.SDL_SCANCODE_KP_5 => return .KP_5,
        c.SDL_SCANCODE_KP_6 => return .KP_6,
        c.SDL_SCANCODE_KP_7 => return .KP_7,
        c.SDL_SCANCODE_KP_8 => return .KP_8,
        c.SDL_SCANCODE_KP_9 => return .KP_9,
        c.SDL_SCANCODE_KP_0 => return .KP_0,
        c.SDL_SCANCODE_KP_PERIOD => return .KP_PERIOD,
        c.SDL_SCANCODE_NONUSBACKSLASH => return .NONUSBACKSLASH,
        c.SDL_SCANCODE_APPLICATION => return .APPLICATION,
        c.SDL_SCANCODE_POWER => return .POWER,
        c.SDL_SCANCODE_KP_EQUALS => return .KP_EQUALS,
        c.SDL_SCANCODE_F13 => return .F13,
        c.SDL_SCANCODE_F14 => return .F14,
        c.SDL_SCANCODE_F15 => return .F15,
        c.SDL_SCANCODE_F16 => return .F16,
        c.SDL_SCANCODE_F17 => return .F17,
        c.SDL_SCANCODE_F18 => return .F18,
        c.SDL_SCANCODE_F19 => return .F19,
        c.SDL_SCANCODE_F20 => return .F20,
        c.SDL_SCANCODE_F21 => return .F21,
        c.SDL_SCANCODE_F22 => return .F22,
        c.SDL_SCANCODE_F23 => return .F23,
        c.SDL_SCANCODE_F24 => return .F24,
        c.SDL_SCANCODE_EXECUTE => return .EXECUTE,
        c.SDL_SCANCODE_HELP => return .HELP,
        c.SDL_SCANCODE_MENU => return .MENU,
        c.SDL_SCANCODE_SELECT => return .SELECT,
        c.SDL_SCANCODE_STOP => return .STOP,
        c.SDL_SCANCODE_AGAIN => return .AGAIN,
        c.SDL_SCANCODE_UNDO => return .UNDO,
        c.SDL_SCANCODE_CUT => return .CUT,
        c.SDL_SCANCODE_COPY => return .COPY,
        c.SDL_SCANCODE_PASTE => return .PASTE,
        c.SDL_SCANCODE_FIND => return .FIND,
        c.SDL_SCANCODE_MUTE => return .MUTE,
        c.SDL_SCANCODE_VOLUMEUP => return .VOLUMEUP,
        c.SDL_SCANCODE_VOLUMEDOWN => return .VOLUMEDOWN,
        c.SDL_SCANCODE_KP_COMMA => return .KP_COMMA,
        c.SDL_SCANCODE_KP_EQUALSAS400 => return .KP_EQUALSAS400,
        c.SDL_SCANCODE_INTERNATIONAL1 => return .INTERNATIONAL1,
        c.SDL_SCANCODE_INTERNATIONAL2 => return .INTERNATIONAL2,
        c.SDL_SCANCODE_INTERNATIONAL3 => return .INTERNATIONAL3,
        c.SDL_SCANCODE_INTERNATIONAL4 => return .INTERNATIONAL4,
        c.SDL_SCANCODE_INTERNATIONAL5 => return .INTERNATIONAL5,
        c.SDL_SCANCODE_INTERNATIONAL6 => return .INTERNATIONAL6,
        c.SDL_SCANCODE_INTERNATIONAL7 => return .INTERNATIONAL7,
        c.SDL_SCANCODE_INTERNATIONAL8 => return .INTERNATIONAL8,
        c.SDL_SCANCODE_INTERNATIONAL9 => return .INTERNATIONAL9,
        c.SDL_SCANCODE_LANG1 => return .LANG1,
        c.SDL_SCANCODE_LANG2 => return .LANG2,
        c.SDL_SCANCODE_LANG3 => return .LANG3,
        c.SDL_SCANCODE_LANG4 => return .LANG4,
        c.SDL_SCANCODE_LANG5 => return .LANG5,
        c.SDL_SCANCODE_LANG6 => return .LANG6,
        c.SDL_SCANCODE_LANG7 => return .LANG7,
        c.SDL_SCANCODE_LANG8 => return .LANG8,
        c.SDL_SCANCODE_LANG9 => return .LANG9,
        c.SDL_SCANCODE_ALTERASE => return .ALTERASE,
        c.SDL_SCANCODE_SYSREQ => return .SYSREQ,
        c.SDL_SCANCODE_CANCEL => return .CANCEL,
        c.SDL_SCANCODE_CLEAR => return .CLEAR,
        c.SDL_SCANCODE_PRIOR => return .PRIOR,
        c.SDL_SCANCODE_RETURN2 => return .RETURN2,
        c.SDL_SCANCODE_SEPARATOR => return .SEPARATOR,
        c.SDL_SCANCODE_OUT => return .OUT,
        c.SDL_SCANCODE_OPER => return .OPER,
        c.SDL_SCANCODE_CLEARAGAIN => return .CLEARAGAIN,
        c.SDL_SCANCODE_CRSEL => return .CRSEL,
        c.SDL_SCANCODE_EXSEL => return .EXSEL,
        c.SDL_SCANCODE_KP_00 => return .KP_00,
        c.SDL_SCANCODE_KP_000 => return .KP_000,
        c.SDL_SCANCODE_THOUSANDSSEPARATOR => return .THOUSANDSSEPARATOR,
        c.SDL_SCANCODE_DECIMALSEPARATOR => return .DECIMALSEPARATOR,
        c.SDL_SCANCODE_CURRENCYUNIT => return .CURRENCYUNIT,
        c.SDL_SCANCODE_CURRENCYSUBUNIT => return .CURRENCYSUBUNIT,
        c.SDL_SCANCODE_KP_LEFTPAREN => return .KP_LEFTPAREN,
        c.SDL_SCANCODE_KP_RIGHTPAREN => return .KP_RIGHTPAREN,
        c.SDL_SCANCODE_KP_LEFTBRACE => return .KP_LEFTBRACE,
        c.SDL_SCANCODE_KP_RIGHTBRACE => return .KP_RIGHTBRACE,
        c.SDL_SCANCODE_KP_TAB => return .KP_TAB,
        c.SDL_SCANCODE_KP_BACKSPACE => return .KP_BACKSPACE,
        c.SDL_SCANCODE_KP_A => return .KP_A,
        c.SDL_SCANCODE_KP_B => return .KP_B,
        c.SDL_SCANCODE_KP_C => return .KP_C,
        c.SDL_SCANCODE_KP_D => return .KP_D,
        c.SDL_SCANCODE_KP_E => return .KP_E,
        c.SDL_SCANCODE_KP_F => return .KP_F,
        c.SDL_SCANCODE_KP_XOR => return .KP_XOR,
        c.SDL_SCANCODE_KP_POWER => return .KP_POWER,
        c.SDL_SCANCODE_KP_PERCENT => return .KP_PERCENT,
        c.SDL_SCANCODE_KP_LESS => return .KP_LESS,
        c.SDL_SCANCODE_KP_GREATER => return .KP_GREATER,
        c.SDL_SCANCODE_KP_AMPERSAND => return .KP_AMPERSAND,
        c.SDL_SCANCODE_KP_DBLAMPERSAND => return .KP_DBLAMPERSAND,
        c.SDL_SCANCODE_KP_VERTICALBAR => return .KP_VERTICALBAR,
        c.SDL_SCANCODE_KP_DBLVERTICALBAR => return .KP_DBLVERTICALBAR,
        c.SDL_SCANCODE_KP_COLON => return .KP_COLON,
        c.SDL_SCANCODE_KP_HASH => return .KP_HASH,
        c.SDL_SCANCODE_KP_SPACE => return .KP_SPACE,
        c.SDL_SCANCODE_KP_AT => return .KP_AT,
        c.SDL_SCANCODE_KP_EXCLAM => return .KP_EXCLAM,
        c.SDL_SCANCODE_KP_MEMSTORE => return .KP_MEMSTORE,
        c.SDL_SCANCODE_KP_MEMRECALL => return .KP_MEMRECALL,
        c.SDL_SCANCODE_KP_MEMCLEAR => return .KP_MEMCLEAR,
        c.SDL_SCANCODE_KP_MEMADD => return .KP_MEMADD,
        c.SDL_SCANCODE_KP_MEMSUBTRACT => return .KP_MEMSUBTRACT,
        c.SDL_SCANCODE_KP_MEMMULTIPLY => return .KP_MEMMULTIPLY,
        c.SDL_SCANCODE_KP_MEMDIVIDE => return .KP_MEMDIVIDE,
        c.SDL_SCANCODE_KP_PLUSMINUS => return .KP_PLUSMINUS,
        c.SDL_SCANCODE_KP_CLEAR => return .KP_CLEAR,
        c.SDL_SCANCODE_KP_CLEARENTRY => return .KP_CLEARENTRY,
        c.SDL_SCANCODE_KP_BINARY => return .KP_BINARY,
        c.SDL_SCANCODE_KP_OCTAL => return .KP_OCTAL,
        c.SDL_SCANCODE_KP_DECIMAL => return .KP_DECIMAL,
        c.SDL_SCANCODE_KP_HEXADECIMAL => return .KP_HEXADECIMAL,
        c.SDL_SCANCODE_LCTRL => return .LCTRL,
        c.SDL_SCANCODE_LSHIFT => return .LSHIFT,
        c.SDL_SCANCODE_LALT => return .LALT,
        c.SDL_SCANCODE_LGUI => return .LGUI,
        c.SDL_SCANCODE_RCTRL => return .RCTRL,
        c.SDL_SCANCODE_RSHIFT => return .RSHIFT,
        c.SDL_SCANCODE_RALT => return .RALT,
        c.SDL_SCANCODE_RGUI => return .RGUI,
        c.SDL_SCANCODE_MODE => return .MODE,
        c.SDL_SCANCODE_AUDIONEXT => return .AUDIONEXT,
        c.SDL_SCANCODE_AUDIOPREV => return .AUDIOPREV,
        c.SDL_SCANCODE_AUDIOSTOP => return .AUDIOSTOP,
        c.SDL_SCANCODE_AUDIOPLAY => return .AUDIOPLAY,
        c.SDL_SCANCODE_AUDIOMUTE => return .AUDIOMUTE,
        c.SDL_SCANCODE_MEDIASELECT => return .MEDIASELECT,
        c.SDL_SCANCODE_WWW => return .WWW,
        c.SDL_SCANCODE_MAIL => return .MAIL,
        c.SDL_SCANCODE_CALCULATOR => return .CALCULATOR,
        c.SDL_SCANCODE_COMPUTER => return .COMPUTER,
        c.SDL_SCANCODE_AC_SEARCH => return .AC_SEARCH,
        c.SDL_SCANCODE_AC_HOME => return .AC_HOME,
        c.SDL_SCANCODE_AC_BACK => return .AC_BACK,
        c.SDL_SCANCODE_AC_FORWARD => return .AC_FORWARD,
        c.SDL_SCANCODE_AC_STOP => return .AC_STOP,
        c.SDL_SCANCODE_AC_REFRESH => return .AC_REFRESH,
        c.SDL_SCANCODE_AC_BOOKMARKS => return .AC_BOOKMARKS,
        c.SDL_SCANCODE_BRIGHTNESSDOWN => return .BRIGHTNESSDOWN,
        c.SDL_SCANCODE_BRIGHTNESSUP => return .BRIGHTNESSUP,
        c.SDL_SCANCODE_DISPLAYSWITCH => return .DISPLAYSWITCH,
        c.SDL_SCANCODE_KBDILLUMTOGGLE => return .KBDILLUMTOGGLE,
        c.SDL_SCANCODE_KBDILLUMDOWN => return .KBDILLUMDOWN,
        c.SDL_SCANCODE_KBDILLUMUP => return .KBDILLUMUP,
        c.SDL_SCANCODE_EJECT => return .EJECT,
        c.SDL_SCANCODE_SLEEP => return .SLEEP,
        c.SDL_SCANCODE_APP1 => return .APP1,
        c.SDL_SCANCODE_APP2 => return .APP2,
        else => std.debug.panic("unknown scancode", .{}),
    }
}

fn sdlToCommonKeycode(key: c.SDL_Keycode) Keycode {
    return switch (key) {
        c.SDLK_0 => ._0,
        c.SDLK_1 => ._1,
        c.SDLK_2 => ._2,
        c.SDLK_3 => ._3,
        c.SDLK_4 => ._4,
        c.SDLK_5 => ._5,
        c.SDLK_6 => ._6,
        c.SDLK_7 => ._7,
        c.SDLK_8 => ._8,
        c.SDLK_9 => ._9,
        c.SDLK_a => .a,
        c.SDLK_AC_BACK => .AC_BACK,
        c.SDLK_AC_BOOKMARKS => .AC_BOOKMARKS,
        c.SDLK_AC_FORWARD => .AC_FORWARD,
        c.SDLK_AC_HOME => .AC_HOME,
        c.SDLK_AC_REFRESH => .AC_REFRESH,
        c.SDLK_AC_SEARCH => .AC_SEARCH,
        c.SDLK_AC_STOP => .AC_STOP,
        c.SDLK_AGAIN => .AGAIN,
        c.SDLK_ALTERASE => .ALTERASE,
        c.SDLK_QUOTE => .QUOTE,
        c.SDLK_APPLICATION => .APPLICATION,
        c.SDLK_AUDIOMUTE => .AUDIOMUTE,
        c.SDLK_AUDIONEXT => .AUDIONEXT,
        c.SDLK_AUDIOPLAY => .AUDIOPLAY,
        c.SDLK_AUDIOPREV => .AUDIOPREV,
        c.SDLK_AUDIOSTOP => .AUDIOSTOP,
        c.SDLK_b => .b,
        c.SDLK_BACKSLASH => .BACKSLASH,
        c.SDLK_BACKSPACE => .BACKSPACE,
        c.SDLK_BRIGHTNESSDOWN => .BRIGHTNESSDOWN,
        c.SDLK_BRIGHTNESSUP => .BRIGHTNESSUP,
        c.SDLK_c => .c,
        c.SDLK_CALCULATOR => .CALCULATOR,
        c.SDLK_CANCEL => .CANCEL,
        c.SDLK_CAPSLOCK => .CAPSLOCK,
        c.SDLK_CLEAR => .CLEAR,
        c.SDLK_CLEARAGAIN => .CLEARAGAIN,
        c.SDLK_COMMA => .COMMA,
        c.SDLK_COMPUTER => .COMPUTER,
        c.SDLK_COPY => .COPY,
        c.SDLK_CRSEL => .CRSEL,
        c.SDLK_CURRENCYSUBUNIT => .CURRENCYSUBUNIT,
        c.SDLK_CURRENCYUNIT => .CURRENCYUNIT,
        c.SDLK_CUT => .CUT,
        c.SDLK_d => .d,
        c.SDLK_DECIMALSEPARATOR => .DECIMALSEPARATOR,
        c.SDLK_DELETE => .DELETE,
        c.SDLK_DISPLAYSWITCH => .DISPLAYSWITCH,
        c.SDLK_DOWN => .DOWN,
        c.SDLK_e => .e,
        c.SDLK_EJECT => .EJECT,
        c.SDLK_END => .END,
        c.SDLK_EQUALS => .EQUALS,
        c.SDLK_ESCAPE => .ESCAPE,
        c.SDLK_EXECUTE => .EXECUTE,
        c.SDLK_EXSEL => .EXSEL,
        c.SDLK_f => .f,
        c.SDLK_F1 => .F1,
        c.SDLK_F10 => .F10,
        c.SDLK_F11 => .F11,
        c.SDLK_F12 => .F12,
        c.SDLK_F13 => .F13,
        c.SDLK_F14 => .F14,
        c.SDLK_F15 => .F15,
        c.SDLK_F16 => .F16,
        c.SDLK_F17 => .F17,
        c.SDLK_F18 => .F18,
        c.SDLK_F19 => .F19,
        c.SDLK_F2 => .F2,
        c.SDLK_F20 => .F20,
        c.SDLK_F21 => .F21,
        c.SDLK_F22 => .F22,
        c.SDLK_F23 => .F23,
        c.SDLK_F24 => .F24,
        c.SDLK_F3 => .F3,
        c.SDLK_F4 => .F4,
        c.SDLK_F5 => .F5,
        c.SDLK_F6 => .F6,
        c.SDLK_F7 => .F7,
        c.SDLK_F8 => .F8,
        c.SDLK_F9 => .F9,
        c.SDLK_FIND => .FIND,
        c.SDLK_g => .g,
        c.SDLK_BACKQUOTE => .BACKQUOTE,
        c.SDLK_h => .h,
        c.SDLK_HELP => .HELP,
        c.SDLK_HOME => .HOME,
        c.SDLK_i => .i,
        c.SDLK_INSERT => .INSERT,
        c.SDLK_j => .j,
        c.SDLK_k => .k,
        c.SDLK_KBDILLUMDOWN => .KBDILLUMDOWN,
        c.SDLK_KBDILLUMTOGGLE => .KBDILLUMTOGGLE,
        c.SDLK_KBDILLUMUP => .KBDILLUMUP,
        c.SDLK_KP_0 => .KP_0,
        c.SDLK_KP_00 => .KP_00,
        c.SDLK_KP_000 => .KP_000,
        c.SDLK_KP_1 => .KP_1,
        c.SDLK_KP_2 => .KP_2,
        c.SDLK_KP_3 => .KP_3,
        c.SDLK_KP_4 => .KP_4,
        c.SDLK_KP_5 => .KP_5,
        c.SDLK_KP_6 => .KP_6,
        c.SDLK_KP_7 => .KP_7,
        c.SDLK_KP_8 => .KP_8,
        c.SDLK_KP_9 => .KP_9,
        c.SDLK_KP_A => .KP_A,
        c.SDLK_KP_AMPERSAND => .KP_AMPERSAND,
        c.SDLK_KP_AT => .KP_AT,
        c.SDLK_KP_B => .KP_B,
        c.SDLK_KP_BACKSPACE => .KP_BACKSPACE,
        c.SDLK_KP_BINARY => .KP_BINARY,
        c.SDLK_KP_C => .KP_C,
        c.SDLK_KP_CLEAR => .KP_CLEAR,
        c.SDLK_KP_CLEARENTRY => .KP_CLEARENTRY,
        c.SDLK_KP_COLON => .KP_COLON,
        c.SDLK_KP_COMMA => .KP_COMMA,
        c.SDLK_KP_D => .KP_D,
        c.SDLK_KP_DBLAMPERSAND => .KP_DBLAMPERSAND,
        c.SDLK_KP_DBLVERTICALBAR => .KP_DBLVERTICALBAR,
        c.SDLK_KP_DECIMAL => .KP_DECIMAL,
        c.SDLK_KP_DIVIDE => .KP_DIVIDE,
        c.SDLK_KP_E => .KP_E,
        c.SDLK_KP_ENTER => .KP_ENTER,
        c.SDLK_KP_EQUALS => .KP_EQUALS,
        c.SDLK_KP_EQUALSAS400 => .KP_EQUALSAS400,
        c.SDLK_KP_EXCLAM => .KP_EXCLAM,
        c.SDLK_KP_F => .KP_F,
        c.SDLK_KP_GREATER => .KP_GREATER,
        c.SDLK_KP_HASH => .KP_HASH,
        c.SDLK_KP_HEXADECIMAL => .KP_HEXADECIMAL,
        c.SDLK_KP_LEFTBRACE => .KP_LEFTBRACE,
        c.SDLK_KP_LEFTPAREN => .KP_LEFTPAREN,
        c.SDLK_KP_LESS => .KP_LESS,
        c.SDLK_KP_MEMADD => .KP_MEMADD,
        c.SDLK_KP_MEMCLEAR => .KP_MEMCLEAR,
        c.SDLK_KP_MEMDIVIDE => .KP_MEMDIVIDE,
        c.SDLK_KP_MEMMULTIPLY => .KP_MEMMULTIPLY,
        c.SDLK_KP_MEMRECALL => .KP_MEMRECALL,
        c.SDLK_KP_MEMSTORE => .KP_MEMSTORE,
        c.SDLK_KP_MEMSUBTRACT => .KP_MEMSUBTRACT,
        c.SDLK_KP_MINUS => .KP_MINUS,
        c.SDLK_KP_MULTIPLY => .KP_MULTIPLY,
        c.SDLK_KP_OCTAL => .KP_OCTAL,
        c.SDLK_KP_PERCENT => .KP_PERCENT,
        c.SDLK_KP_PERIOD => .KP_PERIOD,
        c.SDLK_KP_PLUS => .KP_PLUS,
        c.SDLK_KP_PLUSMINUS => .KP_PLUSMINUS,
        c.SDLK_KP_POWER => .KP_POWER,
        c.SDLK_KP_RIGHTBRACE => .KP_RIGHTBRACE,
        c.SDLK_KP_RIGHTPAREN => .KP_RIGHTPAREN,
        c.SDLK_KP_SPACE => .KP_SPACE,
        c.SDLK_KP_TAB => .KP_TAB,
        c.SDLK_KP_VERTICALBAR => .KP_VERTICALBAR,
        c.SDLK_KP_XOR => .KP_XOR,
        c.SDLK_l => .l,
        c.SDLK_LALT => .LALT,
        c.SDLK_LCTRL => .LCTRL,
        c.SDLK_LEFT => .LEFT,
        c.SDLK_LEFTBRACKET => .LEFTBRACKET,
        c.SDLK_LGUI => .LGUI,
        c.SDLK_LSHIFT => .LSHIFT,
        c.SDLK_m => .m,
        c.SDLK_MAIL => .MAIL,
        c.SDLK_MEDIASELECT => .MEDIASELECT,
        c.SDLK_MENU => .MENU,
        c.SDLK_MINUS => .MINUS,
        c.SDLK_MODE => .MODE,
        c.SDLK_MUTE => .MUTE,
        c.SDLK_n => .n,
        c.SDLK_NUMLOCKCLEAR => .NUMLOCKCLEAR,
        c.SDLK_o => .o,
        c.SDLK_OPER => .OPER,
        c.SDLK_OUT => .OUT,
        c.SDLK_p => .p,
        c.SDLK_PAGEDOWN => .PAGEDOWN,
        c.SDLK_PAGEUP => .PAGEUP,
        c.SDLK_PASTE => .PASTE,
        c.SDLK_PAUSE => .PAUSE,
        c.SDLK_PERIOD => .PERIOD,
        c.SDLK_POWER => .POWER,
        c.SDLK_PRINTSCREEN => .PRINTSCREEN,
        c.SDLK_PRIOR => .PRIOR,
        c.SDLK_q => .q,
        c.SDLK_r => .r,
        c.SDLK_RALT => .RALT,
        c.SDLK_RCTRL => .RCTRL,
        c.SDLK_RETURN => .RETURN,
        c.SDLK_RETURN2 => .RETURN2,
        c.SDLK_RGUI => .RGUI,
        c.SDLK_RIGHT => .RIGHT,
        c.SDLK_RIGHTBRACKET => .RIGHTBRACKET,
        c.SDLK_RSHIFT => .RSHIFT,
        c.SDLK_s => .s,
        c.SDLK_SCROLLLOCK => .SCROLLLOCK,
        c.SDLK_SELECT => .SELECT,
        c.SDLK_SEMICOLON => .SEMICOLON,
        c.SDLK_SEPARATOR => .SEPARATOR,
        c.SDLK_SLASH => .SLASH,
        c.SDLK_SLEEP => .SLEEP,
        c.SDLK_SPACE => .SPACE,
        c.SDLK_STOP => .STOP,
        c.SDLK_SYSREQ => .SYSREQ,
        c.SDLK_t => .t,
        c.SDLK_TAB => .TAB,
        c.SDLK_THOUSANDSSEPARATOR => .THOUSANDSSEPARATOR,
        c.SDLK_u => .u,
        c.SDLK_UNDO => .UNDO,
        c.SDLK_UNKNOWN => .UNKNOWN,
        c.SDLK_UP => .UP,
        c.SDLK_v => .v,
        c.SDLK_VOLUMEDOWN => .VOLUMEDOWN,
        c.SDLK_VOLUMEUP => .VOLUMEUP,
        c.SDLK_w => .w,
        c.SDLK_WWW => .WWW,
        c.SDLK_x => .x,
        c.SDLK_y => .y,
        c.SDLK_z => .z,
        c.SDLK_AMPERSAND => .AMPERSAND,
        c.SDLK_ASTERISK => .ASTERISK,
        c.SDLK_AT => .AT,
        c.SDLK_CARET => .CARET,
        c.SDLK_COLON => .COLON,
        c.SDLK_DOLLAR => .DOLLAR,
        c.SDLK_EXCLAIM => .EXCLAIM,
        c.SDLK_GREATER => .GREATER,
        c.SDLK_HASH => .HASH,
        c.SDLK_LEFTPAREN => .LEFTPAREN,
        c.SDLK_LESS => .LESS,
        c.SDLK_PERCENT => .PERCENT,
        c.SDLK_PLUS => .PLUS,
        c.SDLK_QUESTION => .QUESTION,
        c.SDLK_QUOTEDBL => .QUOTEDBL,
        c.SDLK_RIGHTPAREN => .RIGHTPAREN,
        c.SDLK_UNDERSCORE => .UNDERSCORE,
        else => std.debug.panic("unknown keycode", .{}),
    };
}

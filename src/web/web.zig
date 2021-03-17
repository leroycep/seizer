pub const gl = @import("./webgl.zig");
const std = @import("std");
const Vec2i = @import("math").Vec2i;
const seizer = @import("../seizer.zig");
const App = seizer.App;

pub extern fn now_f64() f64;

pub fn now() u64 {
    return @floatToInt(u64, now_f64());
}

pub extern fn getScreenW() i32;
pub extern fn getScreenH() i32;
pub fn getScreenSize() Vec2i {
    return Vec2i.init(getScreenW(), getScreenH());
}

pub const setShaderSource = glShaderSource;

extern fn seizer_log_write(str_ptr: [*]const u8, str_len: usize) void;
extern fn seizer_log_flush() void;

fn seizerLogWrite(write_context: void, bytes: []const u8) error{}!usize {
    seizer_log_write(bytes.ptr, bytes.len);
    return bytes.len;
}

fn seizerLogWriter() std.io.Writer(void, error{}, seizerLogWrite) {
    return .{ .context = {} };
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = seizerLogWriter();
    defer seizer_log_flush();
    writer.print("[{s}][{s}] ", .{ std.meta.tagName(message_level), std.meta.tagName(scope) }) catch {};
    writer.print(format, args) catch {};
}

pub fn panic(msg: []const u8, stacktrace: ?*std.builtin.StackTrace) noreturn {
    seizer_log_write(msg.ptr, msg.len);
    seizer_log_flush();
    while (true) {
        @breakpoint();
    }
}

pub extern fn seizer_reject_promise(promise_id: usize, errorno: usize) void;
pub extern fn seizer_resolve_promise(promise_id: usize, data: usize) void;

extern fn seizer_run(maxDelta: f64, tickDelta: f64) void;
pub fn run(comptime app: App) void {
    seizer_run(app.maxDeltaSeconds, app.tickDeltaSeconds);

    const S = struct {
        var init_frame: @Frame(onInit_internal) = undefined;

        export fn onInit(promiseId: usize) void {
            init_frame = async onInit_internal(promiseId);
        }

        fn onInit_internal(promiseId: usize) void {
            app.init() catch |err| {
                seizer_reject_promise(promiseId, @errorToInt(err));
                return;
            };
            seizer_resolve_promise(promiseId, 0);
        }

        export fn onMouseMove(x: i32, y: i32, relx: i32, rely: i32, buttons: u32) void {
            catchError(catchError(app.event(.{
                .MouseMotion = .{ .pos = Vec2i.init(x, y), .rel = Vec2i.init(relx, rely), .buttons = buttons },
            })));
        }

        export fn onMouseButton(x: i32, y: i32, down: i32, button_int: u8) void {
            const event = seizer.event.MouseButtonEvent{
                .pos = Vec2i.init(x, y),
                .button = @intToEnum(seizer.event.MouseButton, button_int),
            };
            if (down == 0) {
                catchError(catchError(app.event(.{ .MouseButtonUp = event })));
            } else {
                catchError(catchError(app.event(.{ .MouseButtonDown = event })));
            }
        }

        export fn onMouseWheel(x: i32, y: i32) void {
            catchError(catchError(app.event(.{
                .MouseWheel = Vec2i.init(x, y),
            })));
        }

        export fn onKeyDown(key: u16, scancode: u16) void {
            catchError(app.event(.{
                .KeyDown = .{
                    .key = @intToEnum(seizer.event.Keycode, key),
                    .scancode = @intToEnum(seizer.event.Scancode, scancode),
                },
            }));
        }

        export fn onKeyUp(key: u16, scancode: u16) void {
            catchError(app.event(.{
                .KeyUp = .{
                    .key = @intToEnum(seizer.event.Keycode, key),
                    .scancode = @intToEnum(seizer.event.Scancode, scancode),
                },
            }));
        }

        export const TEXT_INPUT_BUFFER: [32]u8 = undefined;
        export fn onTextInput(len: u8) void {
            catchError(app.event(.{
                .TextInput = .{
                    ._buf = TEXT_INPUT_BUFFER,
                    .text = TEXT_INPUT_BUFFER[0..len],
                },
            }));
        }

        export fn onResize() void {
            catchError(app.event(.{
                .ScreenResized = seizer.getScreenSize(),
            }));
        }

        export fn onCustomEvent(eventId: u32) void {
            catchError(app.event(.{
                .Custom = eventId,
            }));
        }

        export fn update(current_time: f64, delta: f64) void {
            catchError(app.update(current_time, delta));
        }

        export fn render(alpha: f64) void {
            catchError(app.render(alpha));
        }
    };
}

pub fn quit() void {}

const builtin = @import("builtin");

export const SCANCODE_UNKNOWN = @enumToInt(seizer.event.Scancode.UNKNOWN);
export const SCANCODE_ESCAPE = @enumToInt(seizer.event.Scancode.ESCAPE);
export const SCANCODE_W = @enumToInt(seizer.event.Scancode.W);
export const SCANCODE_A = @enumToInt(seizer.event.Scancode.A);
export const SCANCODE_S = @enumToInt(seizer.event.Scancode.S);
export const SCANCODE_D = @enumToInt(seizer.event.Scancode.D);
export const SCANCODE_Z = @enumToInt(seizer.event.Scancode.Z);
export const SCANCODE_R = @enumToInt(seizer.event.Scancode.R);
export const SCANCODE_LEFT = @enumToInt(seizer.event.Scancode.LEFT);
export const SCANCODE_RIGHT = @enumToInt(seizer.event.Scancode.RIGHT);
export const SCANCODE_UP = @enumToInt(seizer.event.Scancode.UP);
export const SCANCODE_DOWN = @enumToInt(seizer.event.Scancode.DOWN);
export const SCANCODE_SPACE = @enumToInt(seizer.event.Scancode.SPACE);
export const SCANCODE_BACKSPACE = @enumToInt(seizer.event.Scancode.BACKSPACE);
export const SCANCODE_NUMPAD0 = @enumToInt(seizer.event.Scancode.KP_0);
export const SCANCODE_NUMPAD1 = @enumToInt(seizer.event.Scancode.KP_1);
export const SCANCODE_NUMPAD2 = @enumToInt(seizer.event.Scancode.KP_2);
export const SCANCODE_NUMPAD3 = @enumToInt(seizer.event.Scancode.KP_3);
export const SCANCODE_NUMPAD4 = @enumToInt(seizer.event.Scancode.KP_4);
export const SCANCODE_NUMPAD5 = @enumToInt(seizer.event.Scancode.KP_5);
export const SCANCODE_NUMPAD6 = @enumToInt(seizer.event.Scancode.KP_6);
export const SCANCODE_NUMPAD7 = @enumToInt(seizer.event.Scancode.KP_7);
export const SCANCODE_NUMPAD8 = @enumToInt(seizer.event.Scancode.KP_8);
export const SCANCODE_NUMPAD9 = @enumToInt(seizer.event.Scancode.KP_9);

export const KEYCODE_UNKNOWN = @enumToInt(seizer.event.Keycode.UNKNOWN);
export const KEYCODE_BACKSPACE = @enumToInt(seizer.event.Keycode.BACKSPACE);

export const MOUSE_BUTTON_LEFT = @enumToInt(seizer.event.MouseButton.Left);
export const MOUSE_BUTTON_MIDDLE = @enumToInt(seizer.event.MouseButton.Middle);
export const MOUSE_BUTTON_RIGHT = @enumToInt(seizer.event.MouseButton.Right);
export const MOUSE_BUTTON_X1 = @enumToInt(seizer.event.MouseButton.X1);
export const MOUSE_BUTTON_X2 = @enumToInt(seizer.event.MouseButton.X2);

// Export errnos
export const ERRNO_OUT_OF_MEMORY = @errorToInt(error.OutOfMemory);
export const ERRNO_FILE_NOT_FOUND = @errorToInt(error.FileNotFound);
export const ERRNO_UNKNOWN = @errorToInt(error.Unknown);

fn catchError(result: anyerror!void) void {
    if (result) |is_void| {} else |err| {
        // TODO: notify JS game loop
        panic("Got error", null);
    }
}

// === Allocator API

export fn wasm_allocator_alloc(allocator: *std.mem.Allocator, num_bytes: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, num_bytes) catch {
        return null;
    };
    return slice.ptr;
}

// === Fetch API
pub const FetchError = error{
    FileNotFound,
    OutOfMemory,
    Unknown,
};

extern fn seizer_fetch(filename_ptr: [*]const u8, filename_len: usize, cb: *c_void, data_out: *FetchError![]u8, allocator: *std.mem.Allocator) void;
pub fn fetch(allocator: *std.mem.Allocator, file_name: []const u8) FetchError![]const u8 {
    var data: FetchError![]u8 = undefined;
    suspend seizer_fetch(file_name.ptr, file_name.len, @frame(), &data, allocator);
    return data;
}

export fn wasm_finalize_fetch(cb_void: *c_void, data_out: *FetchError![]u8, buffer: [*]u8, len: usize) void {
    const cb = @ptrCast(anyframe, @alignCast(8, cb_void));
    data_out.* = buffer[0..len];
    resume cb;
}

export fn wasm_fail_fetch(cb_void: *c_void, data_out: *FetchError![]u8, errno: std.meta.Int(.unsigned, @sizeOf(anyerror) * 8)) void {
    const cb = @ptrCast(anyframe, @alignCast(8, cb_void));
    data_out.* = switch (@intToError(errno)) {
        error.FileNotFound, error.OutOfMemory, error.Unknown => |e| e,
        else => unreachable,
    };
    resume cb;
}

// WASM Error name
export fn wasm_error_name_ptr(errno: std.meta.Int(.unsigned, @sizeOf(anyerror) * 8)) [*]const u8 {
    return @errorName(@intToError(errno)).ptr;
}

export fn wasm_error_name_len(errno: std.meta.Int(.unsigned, @sizeOf(anyerror) * 8)) usize {
    return @errorName(@intToError(errno)).len;
}

// Random bytes
extern fn seizer_random_bytes(ptr: [*]u8, len: usize) void;
pub fn randomBytes(slice: []u8) void {
    seizer_random_bytes(slice.ptr, slice.len);
}

pub const gl = @import("./webgl.zig");
pub const audio = @import("audio.zig");
const std = @import("std");
const Vec2i = @import("math").Vec2i;
const seizer = @import("../seizer.zig");
const App = seizer.App;

pub extern fn now_f64() f64;

pub fn now() i64 {
    return @floatToInt(i64, now_f64());
}

pub extern fn getScreenW() i32;
pub extern fn getScreenH() i32;
pub fn getScreenSize() Vec2i {
    return Vec2i.init(getScreenW(), getScreenH());
}

extern fn seizer_log_write(str_ptr: [*]const u8, str_len: usize) void;
extern fn seizer_log_flush() void;

fn seizerLogWrite(ctx: void, bytes: []const u8) error{}!usize {
    _ = ctx;

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
    _ = stacktrace;

    seizer_log_write(msg.ptr, msg.len);
    seizer_log_flush();
    while (true) {
        @breakpoint();
    }
}

pub extern fn seizer_reject_promise(promise_id: usize, errorno: usize) void;
pub extern fn seizer_resolve_promise(promise_id: usize, data: usize) void;

extern fn seizer_run(maxDelta: f64, tickDelta: f64) void;
pub fn run(comptime app: App) type {
    return struct {
        var init_frame: @Frame(onInit_internal) = undefined;

        export fn _start() void {
            seizer_run(app.maxDeltaSeconds, app.tickDeltaSeconds);
        }

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
            catchError(app.event(.{
                .MouseMotion = .{ .pos = Vec2i.init(x, y), .rel = Vec2i.init(relx, rely), .buttons = buttons },
            }));
        }

        export fn onMouseButton(x: i32, y: i32, down: i32, button_int: u8) void {
            const event = seizer.event.MouseButtonEvent{
                .pos = Vec2i.init(x, y),
                .button = @intToEnum(seizer.event.MouseButton, button_int),
            };
            if (down == 0) {
                catchError(app.event(.{ .MouseButtonUp = event }));
            } else {
                catchError(app.event(.{ .MouseButtonDown = event }));
            }
        }

        export fn onMouseWheel(x: i32, y: i32) void {
            catchError(app.event(.{
                .MouseWheel = Vec2i.init(x, y),
            }));
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
            // NOTE: The values of TEXT_INPUT_BUFFER will not be automatically copied, so manually copy them
            var event = seizer.event.Event{ .TextInput = .{
                .buf = undefined,
                .len = len,
            } };
            std.mem.copy(u8, &event.TextInput.buf, &TEXT_INPUT_BUFFER);
            catchError(app.event(event));
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

comptime {
    _ = @import("./constant_exports.zig");
}

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
    if (result) |_| {} else |_| {
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

extern fn seizer_fetch(filename_ptr: [*]const u8, filename_len: usize, cb: *anyopaque, data_out: *FetchError![]u8, allocator: *const std.mem.Allocator) void;
pub fn fetch(allocator: std.mem.Allocator, file_name: []const u8, max_size: usize) FetchError![]const u8 {
    // TODO: Actually use the provided max size
    _ = max_size;

    var data: FetchError![]u8 = undefined;
    suspend seizer_fetch(file_name.ptr, file_name.len, @frame(), &data, &allocator);
    return data;
}

export fn wasm_finalize_fetch(cb_void: *anyopaque, data_out: *FetchError![]u8, buffer: [*]u8, len: usize) void {
    const cb = @ptrCast(anyframe, @alignCast(@alignOf(anyframe), cb_void));
    data_out.* = buffer[0..len];
    resume cb;
}

export fn wasm_fail_fetch(cb_void: *anyopaque, data_out: *FetchError![]u8, errno: std.meta.Int(.unsigned, @sizeOf(anyerror) * 8)) void {
    const cb = @ptrCast(anyframe, @alignCast(@alignOf(anyframe), cb_void));
    data_out.* = switch (@intToError(errno)) {
        error.FileNotFound, error.OutOfMemory, error.Unknown => |e| e,
        else => unreachable,
    };
    resume cb;
}

// Run async functions
pub fn execute(allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !void {
    const FuncFrame = @Frame(func);
    // TODO: deinit frame when it is complete
    const frame_buf = try allocator.create(FuncFrame);
    var ret: void = {};
    _ = @asyncCall(frame_buf, &ret, func, args);
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

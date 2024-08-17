pub const PLATFORM = seizer.Platform{
    .name = "windows",
    .main = main,
    .allocator = getAllocator,
    .createWindow = createWindow,
    .addButtonInput = undefined,
    .writeFile = undefined,
    .readFile = undefined,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var loop: xev.Loop = undefined;
var h_instance: w32.foundation.HINSTANCE = undefined;
var d2d_factory: *w32.graphics.direct2d.ID2D1Factory = undefined;

pub fn main() anyerror!void {
    const root = @import("root");

    h_instance = w32.system.library_loader.GetModuleHandleW(null) orelse return error.NoHInstance;

    try CHECK(w32.system.com.CoInitialize(null));

    _ = w32.graphics.direct2d.D2D1CreateFactory(.SINGLE_THREADED, w32.graphics.direct2d.IID_ID2D1Factory, null, @ptrCast(&d2d_factory));

    const wc = w32.ui.windows_and_messaging.WNDCLASSW{
        .style = .{},
        .lpfnWndProc = GetWndProcForType(HwndWindow),
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = h_instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = L("Some Menu Name"),
        .lpszClassName = HwndWindow.CLASS_NAME,
    };

    if (w32.ui.windows_and_messaging.RegisterClassW(&wc) == 0) {
        return error.RegisterClass;
    }

    std.log.debug("{s}:{}", .{ @src().file, @src().line });

    root.init() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    var msg: w32.ui.windows_and_messaging.MSG = undefined;
    while (w32.ui.windows_and_messaging.GetMessageW(&msg, null, 0, 0) != 0) {
        try loop.run(.no_wait);
        _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
        _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
    }
}

pub fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn createWindow(options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
    const hwnd_window = try gpa.allocator().create(HwndWindow);
    errdefer gpa.allocator().destroy(hwnd_window);

    const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
        .{},
        HwndWindow.CLASS_NAME,
        L("Hello windows"),
        w32.ui.windows_and_messaging.WS_OVERLAPPEDWINDOW,
        w32.ui.windows_and_messaging.CW_USEDEFAULT,
        w32.ui.windows_and_messaging.CW_USEDEFAULT,
        640,
        480,
        null,
        null,
        h_instance,
        hwnd_window,
    ) orelse return error.CreateWindow;

    _ = w32.ui.windows_and_messaging.ShowWindow(hwnd_window.hwnd, .{ .SHOWNORMAL = 1 });

    hwnd_window.* = .{
        .hwnd = hwnd,
        .options = options,
        .render_target = null,
    };

    return hwnd_window.window();
}

const HwndWindow = struct {
    hwnd: w32.foundation.HWND,
    options: seizer.Platform.CreateWindowOptions,
    render_target: ?*w32.graphics.direct2d.ID2D1HwndRenderTarget,

    pub const INTERFACE = seizer.Window.Interface{
        .getSize = getSize,
        .getFramebufferSize = getSize,
        .createGfxContext = createGfxContext,
        .swapBuffers = swapBuffers,
        .setShouldClose = setShouldClose,
    };

    pub fn window(this: *@This()) seizer.Window {
        return seizer.Window{
            .pointer = this,
            .interface = &INTERFACE,
        };
    }

    pub fn getSize(userdata: ?*anyopaque) [2]f32 {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));

        var rect: w32.foundation.RECT = undefined;
        _ = w32.ui.windows_and_messaging.GetClientRect(this.hwnd, &rect);

        return .{ @floatFromInt(rect.right - rect.left), @floatFromInt(rect.bottom - rect.top) };
    }

    pub fn createGfxContext(userdata: ?*anyopaque) seizer.Gfx {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));

        return seizer.Gfx{
            .ptr = this,
            .interface = &D2D_GFX_INTERFACE,
        };
    }

    fn swapBuffers(userdata: ?*anyopaque) anyerror!void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = this;
        // TODO
    }

    fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = this;
        _ = should_close;
        w32.ui.windows_and_messaging.PostQuitMessage(0);
    }

    const CLASS_NAME = L("Sample Window Class");

    fn OnCreate(this: *@This()) !void {
        try this.createDeviceResources();
    }

    fn OnDestroy(this: *@This()) !void {
        _ = this;
        w32.ui.windows_and_messaging.PostQuitMessage(0);
    }

    fn OnPaint(this: *@This()) !void {
        try this.createDeviceResources();

        try this.options.on_render(this.window());

        _ = w32.graphics.gdi.ValidateRect(this.hwnd, null);
    }

    fn OnSize(this: *@This()) !void {
        var rect: w32.foundation.RECT = undefined;
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(this.hwnd, &rect));

        _ = this.render_target.?.Resize(&.{
            .width = @intCast(rect.right - rect.left),
            .height = @intCast(rect.bottom - rect.top),
        });
    }

    fn OnDisplayChange(this: *@This()) !void {
        _ = w32.graphics.gdi.InvalidateRect(this.hwnd, null, FALSE);
    }

    fn createDeviceResources(this: *@This()) !void {
        if (this.render_target != null) return;

        var rect: w32.foundation.RECT = undefined;
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(this.hwnd, &rect));

        _ = d2d_factory.CreateHwndRenderTarget(
            &.{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .UNKNOWN, .alphaMode = .UNKNOWN },
                .dpiX = 0,
                .dpiY = 0,
                .usage = .{},
                .minLevel = .DEFAULT,
            },
            &.{
                .hwnd = this.hwnd,
                .pixelSize = .{
                    .width = @intCast(rect.right - rect.left),
                    .height = @intCast(rect.bottom - rect.top),
                },
                .presentOptions = .{},
            },
            &this.render_target,
        );
    }

    fn discardDeviceResources(this: *@This()) void {
        if (this.render_target) |r| _ = r.IUnknown.Release();
    }

    const D2D_GFX_INTERFACE = seizer.Gfx.Interface{
        .begin = d2d_begin,
        .clear = d2d_clear,
        .end = d2d_end,
    };

    fn d2d_begin(userdata: ?*anyopaque, options: seizer.Gfx.BeginOptions) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = options;
        _ = this.render_target.?.ID2D1RenderTarget.BeginDraw();
        _ = this.render_target.?.ID2D1RenderTarget.SetTransform(&.{ .Anonymous = .{ .m = .{
            1, 0, 0,
            0, 1, 0,
        } } });
    }

    fn d2d_clear(userdata: ?*anyopaque, options: seizer.Gfx.ClearOptions) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        const color = options.color orelse [4]f32{ 0, 0, 0, 1 };
        _ = this.render_target.?.ID2D1RenderTarget.Clear(&.{
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        });
    }

    fn d2d_end(userdata: ?*anyopaque, options: seizer.Gfx.EndOptions) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = options;
        switch (this.render_target.?.ID2D1RenderTarget.EndDraw(null, null)) {
            w32.foundation.D2DERR_RECREATE_TARGET => {
                this.discardDeviceResources();
            },
            else => {},
        }
    }
};

// Helper functions
const w32Error = error{
    NotImplemented,
    NoSuchInterface,
    InvalidPointer,
    OperationAborted,
    UnspecifiedFailure,
    UnexpectedFailure,
    AccessDenied,
    InvalidHandle,
    OutOfMemory,
    InvalidArgument,
};

fn CHECK(result: w32.foundation.HRESULT) !void {
    if (result >= 0) return;
    const err = switch (result) {
        w32.foundation.E_NOTIMPL => error.NotImplemented,
        w32.foundation.E_NOINTERFACE => error.NoSuchInterface,
        w32.foundation.E_POINTER => error.InvalidPointer,
        w32.foundation.E_ABORT => error.OperationAborted,
        w32.foundation.E_FAIL => error.UnspecifiedFailure,
        w32.foundation.E_UNEXPECTED => error.UnexpectedFailure,
        w32.foundation.E_ACCESSDENIED => error.AccessDenied,
        w32.foundation.E_HANDLE => error.InvalidHandle,
        w32.foundation.E_OUTOFMEMORY => error.OutOfMemory,
        w32.foundation.E_INVALIDARG => error.InvalidArgument,
        else => error.Unknown,
    };

    std.log.info("HRESULT Error Code {}", .{result});

    return err;
}

fn CHECK_UNWRAP(result: w32.foundation.HRESULT) !w32.foundation.HRESULT {
    try CHECK(result);
    return result;
}

fn GetWndProcForType(comptime T: type) w32.ui.windows_and_messaging.WNDPROC {
    return &(struct {
        fn _WndProc(
            handle: w32.foundation.HWND,
            msg: u32,
            wparam: w32.foundation.WPARAM,
            lparam: w32.foundation.LPARAM,
        ) callconv(.C) w32.foundation.LRESULT {
            const WAM = w32.ui.windows_and_messaging;

            instance: {
                const this = InstanceFromWndProc(T, handle, msg, lparam) catch break :instance;
                switch (msg) {
                    WAM.WM_COMMAND => if (@hasDecl(T, "OnCommand")) return ErrToLRESULT(this.OnCommand(wparam)),
                    WAM.WM_CREATE => if (@hasDecl(T, "OnCreate")) return ErrToLRESULT(this.OnCreate()),
                    WAM.WM_DESTROY => if (@hasDecl(T, "OnDestroy")) return ErrToLRESULT(this.OnDestroy()),
                    WAM.WM_DPICHANGED => if (@hasDecl(T, "OnDpiChanged")) return ErrToLRESULT(this.OnDpiChanged(wparam, lparam)),
                    WAM.WM_GETMINMAXINFO => if (@hasDecl(T, "OnGetMinMaxInfo")) return ErrToLRESULT(this.OnGetMinMaxInfo(lparam)),
                    WAM.WM_PAINT => if (@hasDecl(T, "OnPaint")) return ErrToLRESULT(this.OnPaint()),
                    WAM.WM_SIZE => if (@hasDecl(T, "OnSize")) return ErrToLRESULT(this.OnSize()),
                    WAM.WM_DISPLAYCHANGE => if (@hasDecl(T, "OnDisplayChange")) return ErrToLRESULT(this.OnDisplayChange()),
                    else => {},
                }
            }

            return WAM.DefWindowProcW(handle, msg, wparam, lparam);
        }

        fn ErrToLRESULT(maybe_err: anytype) w32.foundation.LRESULT {
            if (maybe_err) {
                return 0;
            } else |err| {
                // TODO: Log error
                std.log.err("Error in callback: {!}", .{err});
                return 1;
            }
        }
    })._WndProc;
}

fn CHECK_BOOL(result: w32.foundation.BOOL) !void {
    if (result == TRUE) return;
    const err = w32.foundation.GetLastError();

    const err_name = @tagName(err);
    std.log.err("Win32 Error encountered: {} (result), {s}", .{ result, err_name });
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace);
    }

    if (err == .NO_ERROR) return;

    return error.Unknown;
}

fn InstanceFromWndProc(comptime T: type, hwnd: w32.foundation.HWND, msg: u32, lparam: w32.foundation.LPARAM) !*T {
    if (msg == w32.ui.windows_and_messaging.WM_CREATE) {
        const unsigned_lparam: usize = @intCast(lparam);
        const create_struct: *w32.ui.windows_and_messaging.CREATESTRUCTW = @ptrFromInt(unsigned_lparam);
        const pointer: *T = @alignCast(@ptrCast(create_struct.lpCreateParams));

        pointer.hwnd = hwnd;

        _ = w32.ui.windows_and_messaging.SetWindowLongPtrW(
            hwnd,
            w32.ui.windows_and_messaging.GWLP_USERDATA,
            @intCast(@intFromPtr(pointer)),
        );

        return pointer;
    } else {
        const userdata = w32.ui.windows_and_messaging.GetWindowLongPtrW(hwnd, w32.ui.windows_and_messaging.GWLP_USERDATA);
        if (userdata == 0) return error.CouldNotGetUserdata;
        const unsigned: usize = @intCast(userdata);
        const pointer: *T = @ptrFromInt(unsigned);
        return pointer;
    }
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const TRUE: w32.foundation.BOOL = 1;
const FALSE: w32.foundation.BOOL = 0;

const xev = @import("xev");
const w32 = @import("zigwin32");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

pub const PLATFORM = seizer.Platform{
    .name = "windows",
    .main = main,
    .gl = @import("gl"),
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
var gl_loader: GlBindingLoader = undefined;
var _helper_window: ?w32.foundation.HWND = null;
var _wgl: ?WGL = null;

pub fn main() anyerror!void {
    const root = @import("root");

    h_instance = w32.system.library_loader.GetModuleHandleW(null) orelse return error.NoHInstance;

    try CHECK(w32.system.com.CoInitialize(null));

    _helper_window = try createHelperWindow();
    _wgl = try initWGL(_helper_window.?);

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
        std.log.debug("Start Loop", .{});
        try loop.run(.no_wait);
        std.log.debug("Pre translate", .{});
        _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
        std.log.debug("Post translate, pre dispatch", .{});
        if (w32.ui.windows_and_messaging.DispatchMessageW(&msg) != 0) {
            break;
        }
        std.log.debug("Post dispatch", .{});
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

    hwnd_window.* = .{
        .hwnd = hwnd,
        .options = options,
    };

    _ = w32.ui.windows_and_messaging.ShowWindow(hwnd_window.hwnd, .{ .SHOWNORMAL = 1 });
    try CHECK_BOOL(w32.graphics.gdi.UpdateWindow(hwnd_window.hwnd));

    return hwnd_window.window();
}

const WGL = struct {
    // functions
    wglGetExtensionsStringEXT: ?*const fn () callconv(std.os.windows.WINAPI) [*:0]const u8,
    wglGetExtensionsStringARB: ?*const fn (w32.graphics.gdi.HDC) callconv(std.os.windows.WINAPI) [*:0]const u8,
    wglCreateContextAttribsARB: ?*const fn (w32.graphics.gdi.HDC, share: ?w32.graphics.open_gl.HGLRC, attrib_list: ?[*]const c_int) callconv(std.os.windows.WINAPI) w32.graphics.open_gl.HGLRC,

    // extension support
    WGL_ARB_create_context: bool,
    WGL_ARB_create_context_profile: bool,
    WGL_EXT_create_context_es2_profile: bool,

    pub fn extensionSupported(this: WGL, extension_query: []const u8) bool {
        var extensions_opt: ?[*:0]const u8 = null;

        if (this.wglGetExtensionsStringARB) |wglGetExtensionsStringARB| {
            extensions_opt = wglGetExtensionsStringARB(w32.graphics.open_gl.wglGetCurrentDC().?);
        } else if (this.wglGetExtensionsStringEXT) |wglGetExtensionsStringEXT| {
            extensions_opt = wglGetExtensionsStringEXT();
        }

        const extensions_ptr = extensions_opt orelse return false;

        const extensions = std.mem.span(extensions_ptr);
        var extension_iter = std.mem.tokenizeScalar(u8, extensions, ' ');
        while (extension_iter.next()) |extension| {
            if (std.mem.eql(u8, extension, extension_query)) {
                return true;
            }
        }
        return false;
    }
};

fn initWGL(helper_window: w32.foundation.HWND) !WGL {
    const dc = w32.graphics.gdi.GetDC(helper_window);

    const pfd = w32.graphics.open_gl.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.graphics.open_gl.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = .{ .DRAW_TO_WINDOW = 1, .SUPPORT_OPENGL = 1, .DOUBLEBUFFER = 1 },
        .iPixelType = .RGBA,
        .cColorBits = 24,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 0,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 0,
        .cStencilBits = 0,
        .cAuxBuffers = 0,
        .iLayerType = .MAIN_PLANE,
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const pixel_format = w32.graphics.open_gl.ChoosePixelFormat(dc, &pfd);
    if (pixel_format == 0) {
        return error.ChoosePixelFormatFailed;
    }
    if (w32.graphics.open_gl.SetPixelFormat(dc, pixel_format, &pfd) == FALSE) {
        return error.SetPixelFormatFailed;
    }

    const wgl_context = w32.graphics.open_gl.wglCreateContext(dc);
    defer _ = w32.graphics.open_gl.wglDeleteContext(wgl_context);

    const previous_device_context = w32.graphics.open_gl.wglGetCurrentDC();
    const previous_wgl_context = w32.graphics.open_gl.wglGetCurrentContext();

    try CHECK_BOOL(w32.graphics.open_gl.wglMakeCurrent(dc, wgl_context));
    defer _ = w32.graphics.open_gl.wglMakeCurrent(previous_device_context, previous_wgl_context);

    var wgl: WGL = undefined;
    wgl.wglGetExtensionsStringEXT = @ptrCast(w32.graphics.open_gl.wglGetProcAddress("wglGetExtensionsStringEXT"));
    wgl.wglGetExtensionsStringARB = @ptrCast(w32.graphics.open_gl.wglGetProcAddress("wglGetExtensionsStringARB"));
    wgl.wglCreateContextAttribsARB = @ptrCast(w32.graphics.open_gl.wglGetProcAddress("wglCreateContextAttribsARB"));

    wgl.WGL_ARB_create_context = wgl.extensionSupported("WGL_ARB_create_context");
    wgl.WGL_ARB_create_context_profile = wgl.extensionSupported("WGL_ARB_create_context_profile");
    wgl.WGL_EXT_create_context_es2_profile = wgl.extensionSupported("WGL_EXT_create_context_es2_profile");

    std.log.debug("{s}:{} {s}", .{ @src().file, @src().line, wgl.wglGetExtensionsStringEXT.?() });
    std.log.debug("{s}:{} {s}", .{ @src().file, @src().line, wgl.wglGetExtensionsStringARB.?(dc.?) });

    return wgl;
}

const HwndWindow = struct {
    hwnd: w32.foundation.HWND,
    options: seizer.Platform.CreateWindowOptions,
    ghdc: ?w32.graphics.gdi.HDC = null,
    hglrc: ?w32.graphics.open_gl.HGLRC = null,

    gl_binding: gl.Binding = undefined,

    pub const INTERFACE = seizer.Window.Interface{
        .getSize = getSize,
        .getFramebufferSize = getSize,
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

    fn swapBuffers(userdata: ?*anyopaque) anyerror!void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        try CHECK_BOOL(w32.graphics.open_gl.SwapBuffers(this.ghdc));
    }

    fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = this;
        if (should_close) {
            w32.ui.windows_and_messaging.PostQuitMessage(0);
        }
    }

    const CLASS_NAME = L("Sample Window Class");

    fn OnCreate(this: *@This()) !void {
        std.log.debug("WM_CREATE", .{});
        this.ghdc = w32.graphics.gdi.GetDC(this.hwnd);
        try this.setupPixelFormat();

        std.log.debug("{s}:{}", .{ @src().file, @src().line });

        if (!_wgl.?.WGL_ARB_create_context or
            !_wgl.?.WGL_ARB_create_context_profile or
            !_wgl.?.WGL_EXT_create_context_es2_profile)
        {
            return error.OpenGLESApiUnavailable;
        }

        const WGL_CONTEXT_ES2_PROFILE_BIT_EXT = 0x00000004;

        var mask: u32 = 0;
        mask |= WGL_CONTEXT_ES2_PROFILE_BIT_EXT;

        this.hglrc = _wgl.?.wglCreateContextAttribsARB.?(this.ghdc.?, null, null);

        const loader = GlBindingLoader{};
        this.gl_binding.init(loader);
        gl.makeBindingCurrent(&this.gl_binding);

        std.log.debug("{s}:{}", .{ @src().file, @src().line });
        w32.ui.windows_and_messaging.PostQuitMessage(0);
    }

    fn OnDestroy(this: *@This()) !void {
        _ = this;
        w32.ui.windows_and_messaging.PostQuitMessage(0);
    }

    fn OnPaint(this: *@This()) !void {
        std.log.debug("WM_PAINT", .{});
        w32.ui.windows_and_messaging.PostQuitMessage(0);
        gl.makeBindingCurrent(&this.gl_binding);
        try this.options.on_render(this.window());

        std.log.debug("gl error = {}", .{gl.getError()});

        var paint_struct: w32.graphics.gdi.PAINTSTRUCT = undefined;
        _ = w32.graphics.gdi.BeginPaint(this.hwnd, &paint_struct) orelse return error.NoDeviceContext;
        try CHECK_BOOL(w32.graphics.gdi.EndPaint(this.hwnd, &paint_struct));
    }

    fn OnSize(this: *@This()) !void {
        var rect: w32.foundation.RECT = undefined;
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(this.hwnd, &rect));

        gl.viewport(0, 0, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));

        // _ = this.render_target.?.Resize(&.{
        //     .width = @intCast(rect.right - rect.left),
        //     .height = @intCast(rect.bottom - rect.top),
        // });
    }

    fn setupPixelFormat(this: *@This()) !void {
        const pfd = w32.graphics.open_gl.PIXELFORMATDESCRIPTOR{
            .nSize = @sizeOf(w32.graphics.open_gl.PIXELFORMATDESCRIPTOR),
            .nVersion = 1,
            .dwFlags = .{ .DRAW_TO_WINDOW = 1, .SUPPORT_OPENGL = 1, .DOUBLEBUFFER = 1 },
            .iPixelType = .RGBA,
            .cColorBits = 24,
            .cRedBits = 0,
            .cRedShift = 0,
            .cGreenBits = 0,
            .cGreenShift = 0,
            .cBlueBits = 0,
            .cBlueShift = 0,
            .cAlphaBits = 0,
            .cAlphaShift = 0,
            .cAccumBits = 0,
            .cAccumRedBits = 0,
            .cAccumGreenBits = 0,
            .cAccumBlueBits = 0,
            .cAccumAlphaBits = 0,
            .cDepthBits = 16,
            .cStencilBits = 0,
            .cAuxBuffers = 0,
            .iLayerType = .MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };

        const pixel_format = w32.graphics.open_gl.ChoosePixelFormat(this.ghdc, &pfd);
        if (pixel_format == 0) {
            return error.ChoosePixelFormatFailed;
        }
        if (w32.graphics.open_gl.SetPixelFormat(this.ghdc, pixel_format, &pfd) == FALSE) {
            return error.SetPixelFormatFailed;
        }
    }

    // const D2D_GFX_INTERFACE = seizer.Gfx.Interface{
    //     .begin = d2d_begin,
    //     .clear = d2d_clear,
    //     .end = d2d_end,
    // };

    // fn d2d_begin(userdata: ?*anyopaque, options: seizer.Gfx.BeginOptions) void {
    //     const this: *@This() = @ptrCast(@alignCast(userdata.?));
    //     _ = options;
    //     _ = this.render_target.?.ID2D1RenderTarget.BeginDraw();
    //     _ = this.render_target.?.ID2D1RenderTarget.SetTransform(&.{ .Anonymous = .{ .m = .{
    //         1, 0, 0,
    //         0, 1, 0,
    //     } } });
    // }

    // fn d2d_clear(userdata: ?*anyopaque, options: seizer.Gfx.ClearOptions) void {
    //     const this: *@This() = @ptrCast(@alignCast(userdata.?));
    //     const color = options.color orelse [4]f32{ 0, 0, 0, 1 };
    //     _ = this.render_target.?.ID2D1RenderTarget.Clear(&.{
    //         .r = color[0],
    //         .g = color[1],
    //         .b = color[2],
    //         .a = color[3],
    //     });
    // }

    // fn d2d_end(userdata: ?*anyopaque, options: seizer.Gfx.EndOptions) void {
    //     const this: *@This() = @ptrCast(@alignCast(userdata.?));
    //     _ = options;
    //     switch (this.render_target.?.ID2D1RenderTarget.EndDraw(null, null)) {
    //         w32.foundation.D2DERR_RECREATE_TARGET => {
    //             // this.discardDeviceResources();
    //         },
    //         else => {},
    //     }
    // }
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

            std.log.debug("msg = {}", .{msg});
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
                if (@errorReturnTrace()) |error_trace| {
                    std.debug.dumpStackTrace(error_trace.*);
                }
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

pub const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(this: @This(), command_name: [:0]const u8) ?AnyCFnPtr {
        _ = this;
        return w32.graphics.open_gl.wglGetProcAddress(command_name);
    }

    pub fn extensionSupported(this: @This(), extension_name: [:0]const u8) bool {
        _ = this;
        _ = extension_name;
        return false;
    }
};

/// Creates a dummy window so we can set up OpenGL before an actual window is created.
fn createHelperWindow() !w32.foundation.HWND {
    const helper_window_class = w32.ui.windows_and_messaging.WNDCLASSW{
        .style = .{ .OWNDC = 1 },
        .lpfnWndProc = HelperWindow._WndProc,
        .hInstance = h_instance,
        .lpszClassName = HelperWindow.CLASS_NAME,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
    };

    if (w32.ui.windows_and_messaging.RegisterClassW(&helper_window_class) == 0) {
        return error.RegisterClassFailed;
    }

    const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
        w32.ui.windows_and_messaging.WS_EX_OVERLAPPEDWINDOW,
        HelperWindow.CLASS_NAME,
        L("seizer helper"),
        .{ .CLIPSIBLINGS = 1, .CLIPCHILDREN = 1 },
        0,
        0,
        1,
        1,
        null,
        null,
        h_instance,
        null,
    ) orelse return error.CreateWindow;

    _ = w32.ui.windows_and_messaging.ShowWindow(hwnd, w32.ui.windows_and_messaging.SW_HIDE);

    var msg: w32.ui.windows_and_messaging.MSG = undefined;
    while (w32.ui.windows_and_messaging.PeekMessageW(&msg, hwnd, 0, 0, @bitCast(w32.ui.windows_and_messaging.PM_REMOVE)) != 0) {
        _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
        _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
    }

    return hwnd;
}

const HelperWindow = struct {
    pub const CLASS_NAME = L("seizer helper");

    fn _WndProc(
        handle: w32.foundation.HWND,
        msg: u32,
        wparam: w32.foundation.WPARAM,
        lparam: w32.foundation.LPARAM,
    ) callconv(.C) w32.foundation.LRESULT {
        const WAM = w32.ui.windows_and_messaging;
        return WAM.DefWindowProcW(handle, msg, wparam, lparam);
    }
};

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const TRUE: w32.foundation.BOOL = 1;
const FALSE: w32.foundation.BOOL = 0;

const gl = @import("gl");
const xev = @import("xev");
const w32 = @import("zigwin32");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

dyn_lib: ?std.DynLib,
api: ?*API_1_6_0,

pub fn loadUsingPrefixes(prefixes: []const []const u8) @This() {
    var dyn_lib = @"dynamic-library-utils".loadFromPrefixes(prefixes, "librenderdoc.so") catch {
        log.debug("\"librenderdoc.so\" not found", .{});
        return @This(){
            .dyn_lib = null,
            .api = null,
        };
    };
    const GetApi = dyn_lib.lookup(PFN_GetAPI, "RENDERDOC_GetAPI") orelse {
        log.warn("entry function \"{}\" librenderdoc.so", .{std.zig.fmtEscapes("RENDERDOC_GetAPI")});
        return @This(){
            .dyn_lib = dyn_lib,
            .api = null,
        };
    };

    var api: ?*API_1_6_0 = null;
    if (GetApi(API_1_6_0.VERSION, @ptrCast(&api)) == 0) {
        log.warn("{} is not supported by librenderdoc.so", .{API_1_6_0.VERSION});
        return @This(){
            .dyn_lib = dyn_lib,
            .api = null,
        };
    }

    log.debug("loaded renderdoc api", .{});
    return @This(){
        .dyn_lib = dyn_lib,
        .api = api.?,
    };
}

pub const CaptureOption = enum(c_int) {
    /// Allow the application to enable vsync
    ///
    /// Default - enabled
    ///
    /// 1 - The application can enable or disable vsync at will
    /// 0 - vsync is force disabled
    AllowVSync = 0,

    /// Allow the application to enable fullscreen
    ///
    /// Default - enabled
    ///
    /// 1 - The application can enable or disable fullscreen at will
    /// 0 - fullscreen is force disabled
    AllowFullscreen = 1,

    /// Record API debugging events and messages
    ///
    /// Default - disabled
    ///
    /// 1 - Enable built-in API debugging features and records the results into
    ///     the capture, which is matched up with events on replay
    /// 0 - no API debugging is forcibly enabled
    APIValidation = 2,

    /// Capture CPU callstacks for API events
    ///
    /// Default - disabled
    ///
    /// 1 - Enables capturing of callstacks
    /// 0 - no callstacks are captured
    CaptureCallstacks = 3,

    /// When capturing CPU callstacks, only capture them from actions.
    /// This option does nothing without the above option being enabled
    ///
    /// Default - disabled
    ///
    /// 1 - Only captures callstacks for actions.
    ///     Ignored if CaptureCallstacks is disabled
    /// 0 - Callstacks, if enabled, are captured for every event.
    CaptureCallstacksOnlyActions = 4,

    /// Specify a delay in seconds to wait for a debugger to attach, after
    /// creating or injecting into a process, before continuing to allow it to run.
    ///
    /// 0 indicates no delay, and the process will run immediately after injection
    ///
    /// Default - 0 seconds
    DelayForDebugger = 5,

    /// Verify buffer access. This includes checking the memory returned by a Map() call to
    /// detect any out-of-bounds modification, as well as initialising buffers with undefined contents
    /// to a marker value to catch use of uninitialised memory.
    ///
    /// NOTE: This option is only valid for OpenGL and D3D11. Explicit APIs such as D3D12 and Vulkan do
    /// not do the same kind of interception & checking and undefined contents are really undefined.
    ///
    /// Default - disabled
    ///
    /// 1 - Verify buffer access
    /// 0 - No verification is performed, and overwriting bounds may cause crashes or corruption in
    ///     RenderDoc.
    VerifyBufferAccess = 6,

    /// Hooks any system API calls that create child processes, and injects
    /// RenderDoc into them recursively with the same options.
    ///
    /// Default - disabled
    ///
    /// 1 - Hooks into spawned child processes
    /// 0 - Child processes are not hooked by RenderDoc
    HookIntoChildren = 7,

    /// By default RenderDoc only includes resources in the final capture necessary
    /// for that frame, this allows you to override that behaviour.
    ///
    /// Default - disabled
    ///
    /// 1 - all live resources at the time of capture are included in the capture
    ///     and available for inspection
    /// 0 - only the resources referenced by the captured frame are included
    RefAllResources = 8,

    /// **NOTE**: As of RenderDoc v1.1 this option has been deprecated. Setting or
    /// getting it will be ignored, to allow compatibility with older versions.
    /// In v1.1 the option acts as if it's always enabled.
    ///
    /// By default RenderDoc skips saving initial states for resources where the
    /// previous contents don't appear to be used, assuming that writes before
    /// reads indicate previous contents aren't used.
    ///
    /// Default - disabled
    ///
    /// 1 - initial contents at the start of each captured frame are saved, even if
    ///     they are later overwritten or cleared before being used.
    /// 0 - unless a read is detected, initial contents will not be saved and will
    ///     appear as black or empty data.
    SaveAllInitials = 9,

    /// In APIs that allow for the recording of command lists to be replayed later,
    /// RenderDoc may choose to not capture command lists before a frame capture is
    /// triggered, to reduce overheads. This means any command lists recorded once
    /// and replayed many times will not be available and may cause a failure to
    /// capture.
    ///
    /// NOTE: This is only true for APIs where multithreading is difficult or
    /// discouraged. Newer APIs like Vulkan and D3D12 will ignore this option
    /// and always capture all command lists since the API is heavily oriented
    /// around it and the overheads have been reduced by API design.
    ///
    /// 1 - All command lists are captured from the start of the application
    /// 0 - Command lists are only captured if their recording begins during
    ///     the period when a frame capture is in progress.
    CaptureAllCmdLists = 10,

    /// Mute API debugging output when the API validation mode option is enabled
    ///
    /// Default - enabled
    ///
    /// 1 - Mute any API debug messages from being displayed or passed through
    /// 0 - API debugging is displayed as normal
    DebugOutputMute = 11,

    /// Option to allow vendor extensions to be used even when they may be
    /// incompatible with RenderDoc and cause corrupted replays or crashes.
    ///
    /// Default - inactive
    ///
    /// No values are documented, this option should only be used when absolutely
    /// necessary as directed by a RenderDoc developer.
    AllowUnsupportedVendorExtensions = 12,

    /// Define a soft memory limit which some APIs may aim to keep overhead under where
    /// possible. Anything above this limit will where possible be saved directly to disk during
    /// capture.
    /// This will cause increased disk space use (which may cause a capture to fail if disk space is
    /// exhausted) as well as slower capture times.
    ///
    /// Not all memory allocations may be deferred like this so it is not a guarantee of a memory
    /// limit.
    ///
    /// Units are in MBs, suggested values would range from 200MB to 1000MB.
    ///
    /// Default - 0 Megabytes
    SoftMemoryLimit = 13,
};

/// Sets an option as a u32 that controls how RenderDoc behaves on capture.
///
/// Returns 1 if the option and value are valid
/// Returns 0 if either is invalid and the option is unchanged
pub const PFN_SetCaptureOptionU32 = *const fn (CaptureOption, value: u32) callconv(.C) c_int;

/// Sets an option as an f32 that controls how RenderDoc behaves on capture.
///
/// Returns 1 if the option and value are valid
/// Returns 0 if either is invalid and the option is unchanged
pub const PFN_SetCaptureOptionF32 = *const fn (CaptureOption, value: f32) callconv(.C) c_int;

/// Gets the current value of an option as a uint32_t
///
/// If the option is invalid, 0xffffffff is returned
pub const PFN_GetCaptureOptionU32 = *const fn (CaptureOption) callconv(.C) u32;

/// Gets the current value of an option as a float
///
/// If the option is invalid, -FLT_MAX is returned
pub const PFN_GetCaptureOptionF32 = *const fn (CaptureOption) callconv(.C) f32;

pub const InputButton = enum(c_int) {
    // '0' - '9' matches ASCII values
    @"0" = 0x30,
    @"1" = 0x31,
    @"2" = 0x32,
    @"3" = 0x33,
    @"4" = 0x34,
    @"5" = 0x35,
    @"6" = 0x36,
    @"7" = 0x37,
    @"8" = 0x38,
    @"9" = 0x39,

    // 'A' - 'Z' matches ASCII values
    A = 0x41,
    B = 0x42,
    C = 0x43,
    D = 0x44,
    E = 0x45,
    F = 0x46,
    G = 0x47,
    H = 0x48,
    I = 0x49,
    J = 0x4A,
    K = 0x4B,
    L = 0x4C,
    M = 0x4D,
    N = 0x4E,
    O = 0x4F,
    P = 0x50,
    Q = 0x51,
    R = 0x52,
    S = 0x53,
    T = 0x54,
    U = 0x55,
    V = 0x56,
    W = 0x57,
    X = 0x58,
    Y = 0x59,
    Z = 0x5A,

    // leave the rest of the ASCII range free
    // in case we want to use it later
    NonPrintable = 0x100,

    Divide,
    Multiply,
    Subtract,
    Plus,

    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    Home,
    End,
    Insert,
    Delete,
    PageUp,
    PageDn,

    Backspace,
    Tab,
    PrtScrn,
    Pause,
};

/// Sets which key or keys can be used to toggle focus between multiple windows
///
/// If keys is NULL or num is 0, toggle keys will be disabled
pub const PFN_SetFocusToggleKeys = *const fn (keys: ?[*]InputButton, num: c_int) callconv(.C) void;

/// Sets which key or keys can be used to capture the next frame
///
/// If keys is NULL or num is 0, capture keys will be disabled
pub const PFN_SetCaptureKeys = *const fn (keys: ?[*]InputButton, num: c_int) callconv(.C) void;

pub const OverlayBits = packed struct(u32) {
    Enabled: bool = true,
    FrameRate: bool = true,
    FrameNumber: bool = true,
    CaptureList: bool = true,
    _reserved: u28 = 0,

    pub const NONE: OverlayBits = @bitCast(0);
};

/// returns the overlay bits that have been set
pub const PFN_GetOverlayBits = *const fn () callconv(.C) OverlayBits;
/// sets the overlay bits with an and & or mask
pub const PFN_MaskOverlayBits = *const fn (and_bits: OverlayBits, or_bits: OverlayBits) callconv(.C) void;

/// this function will attempt to remove RenderDoc's hooks in the application.
///
/// Note: that this can only work correctly if done immediately after
/// the module is loaded, before any API work happens. RenderDoc will remove its
/// injected hooks and shut down. Behaviour is undefined if this is called
/// after any API functions have been called, and there is still no guarantee of
/// success.
pub const PFN_RemoveHooks = *const fn () callconv(.C) void;

/// This function will unload RenderDoc's crash handler.
///
/// If you use your own crash handler and don't want RenderDoc's handler to
/// intercede, you can call this function to unload it and any unhandled
/// exceptions will pass to the next handler.
pub const PFN_UnloadCrashHandler = *const fn () callconv(.C) void;

/// Sets the capture file path template
///
/// pathtemplate is a UTF-8 string that gives a template for how captures will be named
/// and where they will be saved.
///
/// Any extension is stripped off the path, and captures are saved in the directory
/// specified, and named with the filename and the frame number appended. If the
/// directory does not exist it will be created, including any parent directories.
///
/// If pathtemplate is NULL, the template will remain unchanged
///
/// Example:
///
/// SetCaptureFilePathTemplate("my_captures/example");
///
/// Capture #1 -> my_captures/example_frame123.rdc
/// Capture #2 -> my_captures/example_frame456.rdc
pub const PFN_SetCaptureFilePathTemplate = *const fn (path_template: ?[*:0]const u8) callconv(.C) void;

/// returns the current capture path template, see SetCaptureFileTemplate above, as a UTF-8 string
pub const PFN_GetCaptureFilePathTemplate = *const fn () callconv(.C) ?[*:0]const u8;

/// returns the number of captures that have been made
pub const PFN_GetNumCaptures = *const fn () callconv(.C) u32;

/// This function returns the details of a capture, by index. New captures are added
/// to the end of the list.
///
/// filename will be filled with the absolute path to the capture file, as a UTF-8 string
/// pathlength will be written with the length in bytes of the filename string
/// timestamp will be written with the time of the capture, in seconds since the Unix epoch
///
/// Any of the parameters can be NULL and they'll be skipped.
///
/// The function will return 1 if the capture index is valid, or 0 if the index is invalid
/// If the index is invalid, the values will be unchanged
///
/// Note: when captures are deleted in the UI they will remain in this list, so the
/// capture path may not exist anymore.
pub const PFN_GetCapture = *const fn (idx: u32, filename: ?[*]u8, pathlength: ?*u32, timestamp: ?*u64) callconv(.C) u32;

/// Sets the comments associated with a capture file. These comments are displayed in the
/// UI program when opening.
///
/// filePath should be a path to the capture file to add comments to. If set to NULL or ""
/// the most recent capture file created made will be used instead.
/// comments should be a NULL-terminated UTF-8 string to add as comments.
///
/// Any existing comments will be overwritten.
pub const PFN_SetCaptureFileComments = *const fn (filepath: ?[*:0]const u8, comments: [*:0]const u8) callconv(.C) void;

/// returns 1 if the RenderDoc UI is connected to this application, 0 otherwise
pub const PFN_IsTargetControlConnected = *const fn () callconv(.C) u32;

/// This function will launch the Replay UI associated with the RenderDoc library injected
/// into the running application.
///
/// if connectTargetControl is 1, the Replay UI will be launched with a command line parameter
/// to connect to this application
/// cmdline is the rest of the command line, as a UTF-8 string. E.g. a captures to open
/// if cmdline is NULL, the command line will be empty.
///
/// returns the PID of the replay UI if successful, 0 if not successful.
pub const PFN_LaunchReplayUI = *const fn (connect_target_control: u32, cmdline: [*:0]const u8) callconv(.C) u32;

/// Requests that the replay UI show itself (if hidden or not the current top window). This can be
/// used in conjunction with IsTargetControlConnected and LaunchReplayUI to intelligently handle
/// showing the UI after making a capture.
///
/// This will return 1 if the request was successfully passed on, though it's not guaranteed that
/// the UI will be on top in all cases depending on OS rules. It will return 0 if there is no current
/// target control connection to make such a request, or if there was another error
pub const PFN_ShowReplayUI = *const fn () callconv(.C) u32;

/// RenderDoc can return a higher version than requested if it's backwards compatible,
/// this function returns the actual version returned. If a parameter is NULL, it will be
/// ignored and the others will be filled out.
pub const PFN_GetAPIVersion = *const fn (major: ?*c_int, minor: ?*c_int, patch: ?*c_int) callconv(.C) void;

// For vulkan, the value needed is the dispatch table pointer, which sits as the first
// pointer-sized object in the memory pointed to by the VkInstance.
pub const DevicePointer = *opaque {};
pub const WindowHandle = *opaque {};

/// This sets the RenderDoc in-app overlay in the API/window pair as 'active' and it will
/// respond to keypresses. Neither parameter can be NULL
pub const PFN_SetActiveWindow = *const fn (DevicePointer, WindowHandle) callconv(.C) void;

/// capture the next frame on whichever window and API is currently considered active
pub const PFN_TriggerCapture = *const fn () callconv(.C) void;

/// capture the next N frames on whichever window and API is currently considered active
pub const PFN_TriggerMultiFrameCapture = *const fn (num_frames: u32) callconv(.C) void;

// When choosing either a device pointer or a window handle to capture, you can pass NULL.
// Passing NULL specifies a 'wildcard' match against anything. This allows you to specify
// any API rendering to a specific window, or a specific API instance rendering to any window,
// or in the simplest case of one window and one API, you can just pass NULL for both.
//
// In either case, if there are two or more possible matching (device,window) pairs it
// is undefined which one will be captured.
//
// Note: for headless rendering you can pass NULL for the window handle and either specify
// a device pointer or leave it NULL as above.

/// Immediately starts capturing API calls on the specified device pointer and window handle.
///
/// If there is no matching thing to capture (e.g. no supported API has been initialised),
/// this will do nothing.
///
/// The results are undefined (including crashes) if two captures are started overlapping,
/// even on separate devices and/oror windows.
pub const PFN_StartFrameCapture = *const fn (?DevicePointer, ?WindowHandle) callconv(.C) void;

/// Returns whether or not a frame capture is currently ongoing anywhere.
///
/// This will return 1 if a capture is ongoing, and 0 if there is no capture running
pub const PFN_IsFrameCapturing = *const fn (?DevicePointer, ?WindowHandle) callconv(.C) u32;

/// Ends capturing immediately.
///
/// This will return 1 if the capture succeeded, and 0 if there was an error capturing.
pub const PFN_EndFrameCapture = *const fn (?DevicePointer, ?WindowHandle) callconv(.C) u32;

/// Ends capturing immediately and discard any data stored without saving to disk.
///
/// This will return 1 if the capture was discarded, and 0 if there was an error or no capture
/// was in progress
pub const PFN_DiscardFrameCapture = *const fn (?DevicePointer, ?WindowHandle) callconv(.C) u32;

/// Only valid to be called between a call to StartFrameCapture and EndFrameCapture. Gives a custom
/// title to the capture produced which will be displayed in the UI.
///
/// If multiple captures are ongoing, this title will be applied to the first capture to end after
/// this call. The second capture to end will have no title, unless this function is called again.
///
/// Calling this function has no effect if no capture is currently running, and if it is called
/// multiple times only the last title will be used.
pub const PFN_SetCaptureTitle = *const fn (title: [*:0]const u8) callconv(.C) void;

/// RenderDoc uses semantic versioning (http://semver.org/).
///
/// MAJOR version is incremented when incompatible API changes happen.
/// MINOR version is incremented when functionality is added in a backwards-compatible manner.
/// PATCH version is incremented when backwards-compatible bug fixes happen.
///
/// Note that this means the API returned can be higher than the one you might have requested.
/// e.g. if you are running against a newer RenderDoc that supports 1.0.1, it will be returned
/// instead of 1.0.0. You can check this with the GetAPIVersion entry point
pub const APIVersion = enum(c_int) {
    @"1.0.0" = 1_00_00,
    @"1.0.1" = 1_00_01,
    @"1.0.2" = 1_00_02,
    @"1.1.0" = 1_01_00,
    @"1.1.1" = 1_01_01,
    @"1.1.2" = 1_01_02,
    @"1.2.0" = 1_02_00,
    @"1.3.0" = 1_03_00,
    @"1.4.0" = 1_04_00,
    @"1.4.1" = 1_04_01,
    @"1.4.2" = 1_04_02,
    @"1.5.0" = 1_05_00,
    @"1.6.0" = 1_06_00,
    _,
};

pub const API_1_6_0 = extern struct {
    pub const VERSION = APIVersion.@"1.6.0";

    GetAPIVersion: PFN_GetAPIVersion,

    SetCaptureOptionU32: PFN_SetCaptureOptionU32,
    SetCaptureOptionF32: PFN_SetCaptureOptionF32,

    GetCaptureOptionU32: PFN_GetCaptureOptionU32,
    GetCaptureOptionF32: PFN_GetCaptureOptionF32,

    SetFocusToggleKeys: PFN_SetFocusToggleKeys,
    SetCaptureKeys: PFN_SetCaptureKeys,

    GetOverlayBits: PFN_GetOverlayBits,
    MaskOverlayBits: PFN_MaskOverlayBits,

    /// Shutdown was renamed to RemoveHooks in 1.4.1.
    RemoveHooks: PFN_RemoveHooks,

    UnloadCrashHandler: PFN_UnloadCrashHandler,

    /// Get/SetLogFilePathTemplate was renamed to Get/SetCaptureFilePathTemplate in 1.1.2.
    SetCaptureFilePathTemplate: PFN_SetCaptureFilePathTemplate,
    GetCaptureFilePathTemplate: PFN_GetCaptureFilePathTemplate,

    GetNumCaptures: PFN_GetNumCaptures,
    GetCapture: PFN_GetCapture,

    TriggerCapture: PFN_TriggerCapture,

    /// IsRemoteAccessConnected was renamed to IsTargetControlConnected in 1.1.1.
    IsTargetControlConnected: PFN_IsTargetControlConnected,

    LaunchReplayUI: PFN_LaunchReplayUI,

    SetActiveWindow: PFN_SetActiveWindow,

    StartFrameCapture: PFN_StartFrameCapture,
    IsFrameCapturing: PFN_IsFrameCapturing,
    EndFrameCapture: PFN_EndFrameCapture,

    /// new function in 1.1.0
    TriggerMultiFrameCapture: PFN_TriggerMultiFrameCapture,

    /// new function in 1.2.0
    SetCaptureFileComments: PFN_SetCaptureFileComments,

    /// new function in 1.4.0
    DiscardFrameCapture: PFN_DiscardFrameCapture,

    /// new function in 1.5.0
    ShowReplayUI: PFN_ShowReplayUI,

    /// new function in 1.6.0
    SetCaptureTitle: PFN_SetCaptureTitle,
};

/// RenderDoc API entry point
///
/// This entry point can be obtained via GetProcAddress/dlsym if RenderDoc is available.
///
/// The name is the same as the typedef - "RENDERDOC_GetAPI"
///
/// This function is not thread safe, and should not be called on multiple threads at once.
/// Ideally, call this once as early as possible in your application's startup, before doing
/// any API work, since some configuration functionality etc has to be done also before
/// initialising any APIs.
///
/// Parameters:
///   version is a single value from the APIVersion above.
///
///   outAPIPointers will be filled out with a pointer to the corresponding struct of function
///   pointers.
///
/// Returns:
///   1 - if the outAPIPointers has been filled with a pointer to the API struct requested
///   0 - if the requested version is not supported or the arguments are invalid.
///
/// Example code:
///
/// ```
/// #include "renderdoc_app.h"
///
/// RENDERDOC_API_1_1_2 *rdoc_api = NULL;
///
/// // At init, on windows
/// if(HMODULE mod = GetModuleHandleA("renderdoc.dll"))
/// {
///     pRENDERDOC_GetAPI RENDERDOC_GetAPI =
///         (pRENDERDOC_GetAPI)GetProcAddress(mod, "RENDERDOC_GetAPI");
///     int ret = RENDERDOC_GetAPI(eRENDERDOC_API_Version_1_1_2, (void **)&rdoc_api);
///     assert(ret == 1);
/// }
///
/// // At init, on linux/android.
/// // For android replace librenderdoc.so with libVkLayer_GLES_RenderDoc.so
/// if(void *mod = dlopen("librenderdoc.so", RTLD_NOW | RTLD_NOLOAD))
/// {
///     pRENDERDOC_GetAPI RENDERDOC_GetAPI = (pRENDERDOC_GetAPI)dlsym(mod, "RENDERDOC_GetAPI");
///     int ret = RENDERDOC_GetAPI(eRENDERDOC_API_Version_1_1_2, (void **)&rdoc_api);
///     assert(ret == 1);
/// }
///
/// // To start a frame capture, call StartFrameCapture.
/// // You can specify NULL, NULL for the device to capture on if you have only one device and
/// // either no windows at all or only one window, and it will capture from that device.
/// // See the documentation below for a longer explanation
/// if(rdoc_api) rdoc_api->StartFrameCapture(NULL, NULL);
///
/// // Your rendering should happen here
///
/// // stop the capture
/// if(rdoc_api) rdoc_api->EndFrameCapture(NULL, NULL);
/// ```
pub const PFN_GetAPI = *const fn (version: APIVersion, out_api_pointers: *?*anyopaque) callconv(.C) c_int;

const log = std.log.scoped(.renderdoc_app);
const @"dynamic-library-utils" = @import("dynamic-library-utils");
const std = @import("std");

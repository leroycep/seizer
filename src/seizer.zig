// seizer sub libraries
pub const geometry = @import("./geometry.zig");
pub const input = @import("./input.zig");
pub const mem = @import("./mem.zig");
pub const ui = @import("./ui.zig");

pub const Canvas = @import("./Canvas.zig");
pub const Graphics = @import("./Graphics.zig");
pub const NinePatch = @import("./NinePatch.zig");
pub const Platform = @import("./Platform.zig");
pub const Window = @import("./Window.zig");

// re-exported libraries
pub const tvg = @import("tvg");
pub const zigimg = @import("zigimg");

pub const main = platform.main;

pub const platform: Platform = if (builtin.os.tag == .linux or builtin.os.tag.isBSD())
    Platform.linuxbsd.PLATFORM
else if (builtin.os.tag == .wasi)
    Platform.wasm.PLATFORM
else
    @compileError("Unsupported platform " ++ @tagName(builtin.os.tag));

// Non-core seizer sub libraries. This is code that is mostly used to implement seizer, and is not intended for external use.
pub const @"dynamic-library-utils" = @import("dynamic-library-utils");

const builtin = @import("builtin");

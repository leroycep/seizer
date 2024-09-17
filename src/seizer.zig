// seizer sub libraries
pub const geometry = @import("./geometry.zig");
pub const input = @import("./input.zig");
pub const mem = @import("./mem.zig");
pub const ui = @import("./ui.zig");

pub const Canvas = @import("./Canvas.zig");
pub const Display = @import("./Display.zig");
pub const Graphics = @import("./Graphics.zig");

pub const NinePatch = @import("./NinePatch.zig");
pub const Platform = @import("./Platform.zig");

pub const colormaps = @import("./colormaps.zig");

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
pub const meta = @import("./meta.zig");

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

const builtin = @import("builtin");
const std = @import("std");

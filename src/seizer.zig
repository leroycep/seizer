pub const glUtil = @import("./gl_util.zig");
pub const geometry = @import("./geometry.zig");
pub const mem = @import("./mem.zig");
pub const tvg = @import("tvg");
pub const ui = @import("./ui.zig");
pub const zigimg = @import("zigimg");
pub const input = @import("./input.zig");

pub const Canvas = @import("./Canvas.zig");
pub const NinePatch = @import("./NinePatch.zig");
pub const Platform = @import("./Platform.zig");
pub const Texture = @import("./Texture.zig");
pub const Window = @import("./Window.zig");

pub const main = platform.main;
pub const gl = platform.gl;

pub const platform: Platform = if (builtin.os.tag == .linux or builtin.os.tag.isBSD())
    Platform.linuxbsd.PLATFORM
else if (builtin.os.tag == .wasi)
    Platform.wasm.PLATFORM
else
    @compileError("Unsupported platform " ++ @tagName(builtin.os.tag));

const builtin = @import("builtin");

pub fn init(stage: *seizer.Stage) !void {
    const main_window = try stage.createWindow(.{
        .title = "seizer - example - clear",
        .render = .{ .function = &render },
    });
    stage.default_response = main_window.response();
    log.debug("app initialized", .{});
}

pub fn render(ptr: ?*anyopaque, window: *seizer.Window, stage: *seizer.Stage) anyerror!void {
    _ = ptr;
    _ = window;
    _ = stage;
    gl.clearColor(0.0, 0.0, 0.0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

const log = std.log.scoped(.example_clear);

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

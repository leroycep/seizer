pub fn init(stage: *seizer.Stage) !void {
    stage.handler = .{
        .ptr = undefined,
        .interface = .{
            .respond = index,
        },
    };
    log.debug("app initialized", .{});
}

pub fn index(ptr: *anyopaque, stage: *seizer.Stage, request: seizer.Request) anyerror!seizer.Response {
    _ = ptr;
    _ = stage;
    _ = request;
    return seizer.Response{
        .screen = &.{
            .{ .text = "Index" },
            .{ .canvas = .{ .ptr = undefined, .render = render } },
        },
    };
}

var pos = [2]f32{ 0, 0 };
pub fn render(ptr: *anyopaque, canvas: *seizer.Canvas) anyerror!void {
    _ = ptr;

    const size = [2]f32{
        canvas.window_size[0] / 16.0,
        canvas.window_size[1] / 16.0,
    };
    canvas.rect(pos, size, .{});

    pos = .{
        @mod((pos[0] + 1), canvas.window_size[0]),
        canvas.window_size[1] / 2.0,
    };
}

const log = std.log.scoped(.example_canvas);

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

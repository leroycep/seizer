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
    if (request.path.len == 0) {
        return seizer.Response{ .text = "Hello, world!" };
    } else {
        const text = try std.fmt.allocPrint(request.arena, "Hello, {s}!", .{request.path});
        return seizer.Response{ .text = text };
    }
}

const log = std.log.scoped(.example_hello_world);

const seizer = @import("seizer");
const std = @import("std");

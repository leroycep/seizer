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
    if (std.mem.eql(u8, request.path, "assets/wedge.png")) {
        return seizer.Response{
            .image_data = @embedFile("assets/wedge.png"),
        };
    } else if (std.mem.eql(u8, request.path, "screen2")) {
        return seizer.Response{
            .screen = &.{
                .{ .text = "Screen 2" },
            },
        };
    } else if (std.mem.eql(u8, request.path, "image")) {
        return seizer.Response{
            .screen = &.{
                .{ .text = "Image" },
                .{ .image = .{ .source = "assets/wedge.png" } },
            },
        };
    } else {
        return seizer.Response{
            .screen = &.{
                .{ .text = "Index" },
                .{ .link = .{ .text = "Link to screen 2", .href = "screen2" } },
                .{ .link = .{ .text = "Link to image screen", .href = "image" } },
            },
        };
    }
}

const log = std.log.scoped(.example_navigation);

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

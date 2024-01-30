pub fn init(stage: *seizer.Stage) !void {
    _ = stage;
    log.debug("app initialized", .{});
}

const log = std.log.scoped(.example_hello_world);

const seizer = @import("seizer");
const std = @import("std");

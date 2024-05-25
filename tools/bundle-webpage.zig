const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const path_to_wasm_binary = args[1];

    const wasm_binary = try std.fs.cwd().readFileAlloc(gpa.allocator(), path_to_wasm_binary, 4 * 1024 * 1024 * 1024);
    defer gpa.allocator().free(wasm_binary);

    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    try out.writeAll(@embedFile("bundle-webpage/document-header.html"));
    try out.print("<script id=\"z85-encoded-wasm\" decoded-length=\"{}\" type=\"application/json\">{{\"data\":\"{}\"}}</script>\n", .{ wasm_binary.len, z85.fmt(wasm_binary) });

    try out.writeAll("<script>\n");
    try out.writeAll(@embedFile("bundle-webpage/z85.js"));
    try out.writeAll(@embedFile("bundle-webpage/wasi_snapshot_preview1-import.js"));
    try out.writeAll(@embedFile("bundle-webpage/seizer-import.js"));
    try out.writeAll(@embedFile("bundle-webpage/webgl2-import.js"));
    try out.writeAll(@embedFile("bundle-webpage/main.js"));
    try out.writeAll("</script>\n");

    try out.writeAll(@embedFile("bundle-webpage/document-footer.html"));
}

const z85 = struct {
    const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";

    pub fn fmt(slice: []const u8) Formatter {
        return .{ .slice = slice };
    }

    const Formatter = struct {
        slice: []const u8,

        pub fn format(
            this: @This(),
            comptime fmt_text: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt_text;
            _ = options;
            var window_iter = std.mem.window(u8, this.slice, 4, 4);
            while (window_iter.next()) |window| {
                var word_buffer = [4]u8{ 0, 0, 0, 0 };
                @memcpy(word_buffer[0..window.len], window);
                var word = std.mem.readInt(u32, word_buffer[0..], .big);

                var buffer: [5]u8 = undefined;
                for (1..6) |i| {
                    const value = word % 85;
                    buffer[buffer.len - i] = ALPHABET[value];
                    word /= 85;
                }

                try writer.writeAll(buffer[0..]);
            }
        }
    };

    test {
        try std.testing.expectFmt("HelloWorld", "{}", .{fmt(&.{ 0x86, 0x4f, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B })});
    }
};

comptime {
    _ = z85;
}

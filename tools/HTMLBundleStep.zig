//! A small script for bundling seizer.js into a single html file
const std = @import("std");

const KB = 1024;
const MB = 1024 * KB;

const BundleStep = @This();

step: std.build.Step,
builder: *std.build.Builder,

path: []const u8,
js_path: std.build.FileSource,
wasm_path: std.build.FileSource,
output_name: []const u8,
title: []const u8,
description: []const u8,
icon_url: ?[]const u8,
resolution: @Vector(2, i16),

pub fn create(b: *std.build.Builder, opt: struct {
    path: []const u8,
    js_path: std.build.FileSource,
    wasm_path: std.build.FileSource,
    output_name: []const u8 = "index.html",
    title: []const u8 = "Seizer Example",
    description: []const u8 = "A Seizer Example Game",
    icon_url: ?[]const u8 = null,
    resolution: @Vector(2, i16) = @Vector(2, i16){640, 480},
}) *@This() {
    var result = b.allocator.create(BundleStep) catch @panic("memory");
    result.* = BundleStep{
        .step = std.build.Step.init(.custom, "create a html file with seizer.js bundle bundledd", b.allocator, make),
        .builder = b,
        .path = opt.path,
        .js_path = opt.js_path,
        .wasm_path = opt.wasm_path,
        .output_name = opt.output_name,
        .title = opt.title,
        .description = opt.description,
        .icon_url = opt.icon_url,
        .resolution = opt.resolution,
    };
    // result.builder.installBinFile(opt.output_name, opt.output_name);
    return result;
}

const template = @embedFile("template.html");

const TemplateVars = struct {
    metadata: []const u8,
    description: []const u8,
    iconUrl: []const u8,
    title: []const u8,
    js: []const u8,
    wasmFile: []const u8,
    width: i16,
    height: i16,
};

fn make(step: *std.build.Step) !void {
    const this = @fieldParentPtr(BundleStep, "step", step);

    const js_path = this.js_path.getPath(this.builder);
    const wasm_path = std.fs.path.basename(this.wasm_path.getPath(this.builder));
    const output = this.builder.getInstallPath(.{.custom = this.path}, this.output_name);

    const allocator = this.builder.allocator;
    const cwd = std.fs.cwd();

    const js = js: {
        const js_file = try cwd.openFile(js_path, .{});
        defer js_file.close();
        break :js try js_file.readToEndAlloc(allocator, 1 * MB);
    };
    defer allocator.free(js);

    const metadata = this.builder.fmt("<meta name=\"{s}\" content=\"{s}\">", .{ "generator", "seizer 0.0.0" });
    const description = this.builder.fmt("<meta name=\"{s}\" content=\"{s}\">", .{ "description", this.description });

    const vars = TemplateVars{
        .metadata = metadata,
        .description = description,
        .iconUrl = this.icon_url orelse "",
        .title = this.title,
        .js = js,
        .wasmFile = wasm_path,
        .width = this.resolution[0],
        .height = this.resolution[1],
    };

    const renderedHTML = try std.fmt.allocPrint(allocator, template, vars);
    defer allocator.free(renderedHTML);

    cwd.makePath(this.builder.getInstallPath(.bin, "")) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    try cwd.writeFile(output, renderedHTML);
}
const std = @import("std");
const Builder = std.build.Builder;
const HTMLBundleStep = @import("tools/HTMLBundleStep.zig");

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Download git repositories
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("seizer", .{
        .source_file = .{ .path = "src/seizer.zig" },
        .dependencies = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });

    const library = b.addStaticLibrary(.{
        .name = "seizer",
        .target = target,
        .optimize = optimize,
    });
    library.install();
    library.linkLibC();
    library.linkSystemLibrary("sdl2");

    {
        const exe = b.addExecutable(.{
            .name = "clear",
            .root_source_file = .{ .path = "examples/clear.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.install();
        exe.linkLibrary(library);
        exe.addModule("seizer", module);
    }
    {
        const exe = b.addExecutable(.{
            .name = "textures",
            .root_source_file = .{ .path = "examples/textures.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.install();
        exe.linkLibrary(library);
        exe.addModule("seizer", module);
    }
    {
        const exe = b.addExecutable(.{
            .name = "bitmap_font",
            .root_source_file = .{ .path = "examples/bitmap_font.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.install();
        exe.linkLibrary(library);
        exe.addModule("seizer", module);
    }
}

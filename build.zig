const std = @import("std");
const Builder = std.Build;

const Example = enum {
    clear,
    textures,
    bitmap_font,
    sprite_batch,
    ui,
    tinyvg,
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const mach_glfw = b.dependency("mach-glfw", .{
        .target = target,
        .optimize = optimize,
    });

    const tinyvg = b.dependency("tinyvg", .{
        .target = target,
        .optimize = optimize,
    });

    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    });

    const gl_module = b.addModule("gl", .{
        .root_source_file = .{ .path = "dep/gles3v0.zig" },
    });

    const egl_module = b.addModule("EGL", .{
        .root_source_file = .{ .path = "dep/EGL.zig" },
    });

    // seizer
    const module = b.addModule("seizer", .{
        .root_source_file = .{ .path = "src/seizer.zig" },
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "tvg", .module = tinyvg.module("tvg") },
            .{ .name = "gl", .module = gl_module },
            .{ .name = "EGL", .module = egl_module },
            .{ .name = "zflecs", .module = zflecs.module("zflecs") },
            .{ .name = "mach-glfw", .module = mach_glfw.module("mach-glfw") },
        },
    });

    const example_fields = @typeInfo(Example).Enum.fields;
    inline for (example_fields) |tag| {
        const tag_name = tag.name;
        const exe = b.addExecutable(.{
            .name = tag_name,
            .root_source_file = .{ .path = "examples/" ++ tag_name ++ ".zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("seizer", module);

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);

        // build
        const build_step = b.step("example-" ++ tag_name, "Build the " ++ tag_name ++ " example");
        build_step.dependOn(&install_exe.step);

        // run
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("example-" ++ tag_name ++ "-run", "Run the " ++ tag_name ++ " example");
        run_step.dependOn(&run_cmd.step);
    }
}

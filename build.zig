const std = @import("std");
const Builder = std.Build;

const Example = enum {
    clear,
    textures,
    bitmap_font,
    sprite_batch,
    tinyvg,
    gamepad,
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
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

    const test_all = b.step("test-all", "run all tests");

    const test_gamepad_exe = b.addTest(.{
        .root_source_file = .{ .path = "src/Gamepad.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_gamepad_run_exe = b.addRunArtifact(test_gamepad_exe);
    const test_gamepad = b.step("test-gamepad", "Run gamepad tests");
    test_gamepad.dependOn(&test_gamepad_run_exe.step);

    test_all.dependOn(test_gamepad);
}

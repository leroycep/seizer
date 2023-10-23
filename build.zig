const std = @import("std");
const Builder = std.build.Builder;

const Example = enum {
    clear,
    textures,
    bitmap_font,
    sprite_batch,
    ui,
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const glfw_dep = b.dependency("glfw", .{
        .target = target,
        .optimize = optimize,
        .opengl = true,
    });

    const gl_module = b.addModule("gl", .{
        .source_file = .{ .path = "dep/gles3v0.zig" },
    });

    // seizer
    const module = b.addModule("seizer", .{
        .source_file = .{ .path = "src/seizer.zig" },
        .dependencies = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "gl", .module = gl_module },
        },
    });

    const example_option = b.option(Example, "example", "Specify which example to run/build/install");

    const example_fields = @typeInfo(Example).Enum.fields;
    inline for (example_fields) |tag| {
        const tag_name = tag.name;
        const exe = b.addExecutable(.{
            .name = tag_name,
            .root_source_file = .{ .path = "examples/" ++ tag_name ++ ".zig" },
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(exe);
        exe.linkLibrary(glfw_dep.artifact("glfw"));
        exe.addModule("seizer", module);
        exe.linkLibC();

        if (example_option != null and std.mem.eql(u8, tag_name, @tagName(example_option.?))) {
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());

            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step("run", "Run the example specified by -Dexample");
            run_step.dependOn(&run_cmd.step);
        }
    }
}

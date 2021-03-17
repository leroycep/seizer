const std = @import("std");
const Builder = std.build.Builder;
const deps = @import("./deps.zig");

const SEIZER = std.build.Pkg{
    .name = "seizer",
    .path = "src/seizer.zig",
    .dependencies = &[_]std.build.Pkg{deps.pkgs.math},
};

const EXAMPLES = [_]std.build.Pkg{
    .{
        .name = "clear",
        .path = "examples/clear.zig",
        .dependencies = &[_]std.build.Pkg{SEIZER},
    },
};

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // Install example assets to "<prefix>/www". By default this means "zig-cache/www"
    const install_assets_web = b.addInstallDirectory(.{
        .source_dir = "examples/assets",
        .install_dir = .Prefix,
        .install_subdir = "www",
    });

    // Install `seizer.js` to "<prefix>/www". By default this means "zig-cache/www"
    const install_seizerjs = b.addInstallFile("src/web/seizer.js", "www/seizer.js");

    var build_examples_native = b.step("examples-native", "Build all examples for the target platform");
    var build_examples_web = b.step("examples-web", "Build all examples for the web");

    inline for (EXAMPLES) |example| {
        // ==== Create native executable and step to run it ====
        const native = b.addExecutable("example-" ++ example.name ++ "-desktop", example.path);
        native.setTarget(target);
        native.setBuildMode(mode);
        native.install();
        native.linkLibC();
        native.linkSystemLibrary("SDL2");
        native.packages.appendSlice(example.dependencies orelse &[_]std.build.Pkg{}) catch unreachable;

        b.step("example-" ++ example.name ++ "-native", "Build native binary").dependOn(&native.step);
        build_examples_native.dependOn(&native.step);

        const native_run = native.run();
        // Start the program in the directory with the assets in it
        native_run.cwd = "examples/assets";

        const native_run_step = b.step("example-" ++ example.name ++ "-run", "Run the " ++ example.name ++ " example");
        native_run_step.dependOn(&native_run.step);

        // ==== Create WASM binary and step to install it ====
        const web = b.addStaticLibrary("example-" ++ example.name ++ "-web", example.path);
        web.setBuildMode(mode);
        web.setOutputDir(b.fmt("{s}/www", .{b.install_prefix}));
        web.setTarget(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });
        web.packages.appendSlice(example.dependencies orelse &[_]std.build.Pkg{}) catch unreachable;

        const install_index = b.addInstallFile("examples/" ++ example.name ++ ".html", "www/" ++ example.name ++ ".html");

        const build_web = b.step("example-" ++ example.name ++ "-web", "Build the " ++ example.name ++ " example for the web");
        build_web.dependOn(&web.step);
        build_web.dependOn(&install_assets_web.step);
        build_web.dependOn(&install_seizerjs.step);
        build_web.dependOn(&install_index.step);

        build_examples_web.dependOn(build_web);
    }
}

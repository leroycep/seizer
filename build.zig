const std = @import("std");
const Builder = std.build.Builder;
const GitRepoStep = @import("tools/GitRepoStep.zig");
const HTMLBundleStep = @import("tools/HTMLBundleStep.zig");

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // Install example assets to "<prefix>/www". By default this means "zig-cache/www"
    const install_assets_web = b.addInstallDirectory(.{
        .source_dir = "examples/assets",
        .install_dir = .prefix,
        .install_subdir = "www",
    });

    // Install `seizer.js` to "<prefix>/www". By default this means "zig-cache/www"
    const seizerjs = std.build.FileSource{ .path = "src/web/seizer.js" };
    const install_seizerjs = b.addInstallFile(.{ .path = "src/web/seizer.js" }, "www/seizer.js");
    const install_audio_enginejs = b.addInstallFile(.{ .path = "src/web/audio_engine.js" }, "www/audio_engine.js");

    var build_examples_native = b.step("examples-native", "Build all examples for the target platform");
    var build_examples_web = b.step("examples-web", "Build all examples for the web");

    // Download git repositories
    const math_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/leroycep/zigmath",
        .branch = "master",
        .sha = "2f404f0af1f07f0cbdd72da58b5941aa374dfc12",
    });
    const zigimg_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/zigimg/zigimg",
        .branch = "master",
        .sha = "ed46298464cdef9f7aa97ae1d817bf621424419a"
    });

    // Create fetch step to simplify adding dependencies
    const fetch = b.step("fetch", "download dependencies");
    fetch.dependOn(&math_repo.step);
    fetch.dependOn(&zigimg_repo.step);

    const math_pkg = std.build.Pkg{ .name = "math", .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8{ math_repo.getPath(fetch), "math.zig" }) } };
    const zigimg_pkg = std.build.Pkg{ .name = "zigimg", .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8{ zigimg_repo.getPath(fetch), "zigimg.zig" }) } };

    const SEIZER = std.build.Pkg{
        .name = "seizer",
        .path = .{ .path = "src/seizer.zig" },
        .dependencies = &[_]std.build.Pkg{ math_pkg, zigimg_pkg },
    };

    const EXAMPLES = [_]std.build.Pkg{
        .{
            .name = "clear",
            .path = .{ .path = "examples/clear.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "scene",
            .path = .{ .path = "examples/scene.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "textures",
            .path = .{ .path = "examples/textures.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "sprite_batch",
            .path = .{ .path = "examples/sprite_batch.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "bitmap_font",
            .path = .{ .path = "examples/bitmap_font.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "play_wav",
            .path = .{ .path = "examples/play_wav.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
        .{
            .name = "ui",
            .path = .{ .path = "examples/ui.zig" },
            .dependencies = &[_]std.build.Pkg{SEIZER},
        },
    };

    for (EXAMPLES) |ex| {
        const example = b.dupePkg(ex);
        const name = example.name;
        // ==== Create native executable and step to run it ====
        const native = b.addExecutable(b.fmt("example-{s}-desktop", .{name}), example.path.path);
        native.step.dependOn(fetch);
        native.setTarget(target);
        native.setBuildMode(mode);
        native.install();
        native.linkLibC();
        native.linkSystemLibrary("SDL2");
        native.packages.appendSlice(example.dependencies orelse &[_]std.build.Pkg{}) catch unreachable;

        b.step(b.fmt("example-{s}-native", .{name}), b.dupe("Build native binary")).dependOn(&native.step);
        build_examples_native.dependOn(fetch);
        build_examples_native.dependOn(&native.step);

        const native_run = native.run();
        // Start the program in the directory with the assets in it
        native_run.cwd = b.dupePath("examples/assets");

        const native_run_step = b.step(b.fmt("example-{s}-run", .{name}), b.fmt("Run the {s} example", .{name}));
        native_run_step.dependOn(fetch);
        native_run_step.dependOn(&native_run.step);

        // ==== Create WASM binary and step to install it ====
        const web = b.addSharedLibrary(b.fmt("example-{s}-web", .{name}), example.path.path, .unversioned);
        web.step.dependOn(fetch);
        web.setBuildMode(mode);
        web.setOutputDir(b.fmt("{s}/www", .{b.install_prefix}));
        web.setTarget(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });
        web.packages.appendSlice(example.dependencies orelse &[_]std.build.Pkg{}) catch unreachable;

        const install_html = HTMLBundleStep.create(b, .{
            .path = "www",
            .js_path = seizerjs,
            .wasm_path = web.getOutputSource(),
            .output_name = b.fmt("{s}.html", .{name}),
            .title = name,
        });

        const build_web = b.step(b.fmt("example-{s}-web", .{name}), b.fmt("Build the {s} example for the web", .{name}));
        build_web.dependOn(fetch);
        build_web.dependOn(&web.step);
        build_web.dependOn(&install_assets_web.step);
        build_web.dependOn(&install_seizerjs.step);
        build_web.dependOn(&install_audio_enginejs.step);
        build_web.dependOn(&install_html.step);

        build_examples_web.dependOn(build_web);
    }

    b.getInstallStep().dependOn(fetch);
    b.getInstallStep().dependOn(build_examples_web);
}

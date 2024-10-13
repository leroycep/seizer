const std = @import("std");
const Builder = std.Build;

const Example = enum {
    clear,
    textures,
    bitmap_font,
    sprite_batch,
    tinyvg,
    gamepad,
    clicker,
    ui_stage,
    multi_window,
    file_browser,
    ui_view_image,
    ui_plot_sine,
    colormapped_image,
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const import_wayland = b.option(bool, "wayland", "enable wayland display backend (defaults to true on linux)") orelse switch (target.result.os.tag) {
        .linux => true,
        .windows => false,
        else => false,
    };

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const tinyvg = b.dependency("tinyvg", .{
        .target = target,
        .optimize = optimize,
    });

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    const xkb_dep = b.dependency("xkb", .{
        .target = target,
        .optimize = optimize,
    });

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("dep/vk.xml")),
    });
    const vkzig_bindings = vkzig_dep.module("vulkan-zig");

    const gl_module = b.addModule("gl", .{
        .root_source_file = b.path("dep/gles3v0.zig"),
    });

    const dynamic_library_utils_module = b.addModule("dynamic-library-utils", .{
        .root_source_file = b.path("dep/dynamic-library-utils.zig"),
    });

    const angelcode_font_module = b.addModule("AngelCodeFont", .{
        .root_source_file = b.path("dep/AngelCodeFont.zig"),
    });

    const renderdoc_app_module = b.addModule("renderdoc_app", .{
        .root_source_file = b.path("dep/renderdoc_app.zig"),
        .imports = &.{
            .{ .name = "dynamic-library-utils", .module = dynamic_library_utils_module },
        },
    });

    const egl_module = b.addModule("EGL", .{
        .root_source_file = b.path("dep/EGL.zig"),
        .imports = &.{
            .{ .name = "dynamic-library-utils", .module = dynamic_library_utils_module },
        },
    });

    const generate_wayland_step = b.step("generate-wayland-protocols", "Generate wayland-protocols and copy files to source repository. Does nothing if `generate-wayland-protocols` option is false.");

    const shimizu_dep = b.dependency("shimizu", .{
        .target = target,
        .optimize = optimize,
    });

    // generate additional wayland protocol definitions with shimizu-scanner
    const generate_wayland_unstable_zig_cmd = b.addRunArtifact(shimizu_dep.artifact("shimizu-scanner"));
    generate_wayland_unstable_zig_cmd.addFileArg(b.path("dep/wayland-protocols/xdg-decoration-unstable-v1.xml"));
    generate_wayland_unstable_zig_cmd.addFileArg(b.path("dep/wayland-protocols/fractional-scale-v1.xml"));
    generate_wayland_unstable_zig_cmd.addArgs(&.{ "--interface-version", "zxdg_decoration_manager_v1", "1" });
    generate_wayland_unstable_zig_cmd.addArgs(&.{ "--interface-version", "wp_fractional_scale_manager_v1", "1" });

    generate_wayland_unstable_zig_cmd.addArg("--import");
    generate_wayland_unstable_zig_cmd.addFileArg(shimizu_dep.path("src/wayland.xml"));
    generate_wayland_unstable_zig_cmd.addArg("@import(\"core\")");

    generate_wayland_unstable_zig_cmd.addArg("--import");
    generate_wayland_unstable_zig_cmd.addFileArg(shimizu_dep.path("wayland-protocols/stable/xdg-shell.xml"));
    generate_wayland_unstable_zig_cmd.addArg("@import(\"wayland-protocols\").xdg_shell");

    generate_wayland_unstable_zig_cmd.addArg("--output");
    const wayland_unstable_dir = generate_wayland_unstable_zig_cmd.addOutputDirectoryArg("wayland-unstable");

    const wayland_unstable_module = b.addModule("wayland-unstable", .{
        .root_source_file = wayland_unstable_dir.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wire", .module = shimizu_dep.module("wire") },
            .{ .name = "core", .module = shimizu_dep.module("core") },
            .{ .name = "wayland-protocols", .module = shimizu_dep.module("wayland-protocols") },
        },
    });

    // a tool that bundles a wasm binary into an html file
    const bundle_webpage_exe = b.addExecutable(.{
        .name = "bundle-webpage",
        .root_source_file = b.path("tools/bundle-webpage.zig"),
        .target = b.graph.host,
    });
    b.installArtifact(bundle_webpage_exe);

    // seizer
    const module = b.addModule("seizer", .{
        .root_source_file = b.path("src/seizer.zig"),
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "tvg", .module = tinyvg.module("tvg") },
            .{ .name = "renderdoc", .module = renderdoc_app_module },
            .{ .name = "gl", .module = gl_module },
            .{ .name = "xev", .module = libxev.module("xev") },
            .{ .name = "dynamic-library-utils", .module = dynamic_library_utils_module },
            .{ .name = "AngelCodeFont", .module = angelcode_font_module },
        },
    });
    module.link_libc = true;

    if (target.result.os.tag == .wasi) {
        module.export_symbol_names = &.{
            "_render",
            "_key_event",
            "_dispatch_read_file_completion",
            "_dispatch_write_file_completion",
        };
    }

    const import_egl = target.result.os.tag != .wasi;
    if (import_egl) {
        module.addImport("EGL", egl_module);
    }

    const vulkan_compile_shaders_step = b.step("vulkan-compile-shaders", "Compile Canvas shaders to SPIR-V using glslc (requires glslc to be installed)");
    const vulkan_compile_shaders = b.option(bool, "vulkan-compile-shaders", "Make examples depend on vulkan shaders being built") orelse false;
    {
        const compile_vertex_shader = b.addSystemCommand(&.{ "glslc", "-fshader-stage=vertex", "src/Canvas/default_shader.vertex.vulkan.glsl", "-o", "src/Canvas/default_shader.vertex.vulkan.spv" });
        const compile_fragment_shader = b.addSystemCommand(&.{ "glslc", "-fshader-stage=fragment", "src/Canvas/default_shader.fragment.vulkan.glsl", "-o", "src/Canvas/default_shader.fragment.vulkan.spv" });

        vulkan_compile_shaders_step.dependOn(&compile_vertex_shader.step);
        vulkan_compile_shaders_step.dependOn(&compile_fragment_shader.step);
    }

    const import_vulkan = true;
    if (import_vulkan) {
        module.addImport("vulkan", vkzig_bindings);
    }

    if (import_wayland) {
        module.addImport("shimizu", shimizu_dep.module("shimizu"));
        module.addImport("wayland-protocols", shimizu_dep.module("wayland-protocols"));
        module.addImport("wayland-unstable", wayland_unstable_module);
        module.addImport("xkb", xkb_dep.module("xkb"));
    }

    const check_step = b.step("check", "check that everything compiles");

    const example_fields = @typeInfo(Example).Enum.fields;
    inline for (example_fields) |tag| {
        const tag_name = tag.name;
        const exe = b.addExecutable(.{
            .name = tag_name,
            .root_source_file = b.path("examples/" ++ tag_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("seizer", module);
        exe.step.dependOn(generate_wayland_step);
        if (vulkan_compile_shaders) {
            exe.step.dependOn(vulkan_compile_shaders_step);
        }

        if (target.result.os.tag == .wasi) {
            exe.wasi_exec_model = .reactor;
        }

        // build
        const build_step = b.step("example-" ++ tag_name, "Build the " ++ tag_name ++ " example");

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        build_step.dependOn(&install_exe.step);

        // additionally generate an HTML file with the wasm module embedded when we use the wasi target
        if (target.result.os.tag == .wasi) {
            const bundle_webpage = b.addRunArtifact(bundle_webpage_exe);
            bundle_webpage.addArtifactArg(exe);

            const install_html = b.addInstallFile(bundle_webpage.captureStdOut(), "www/" ++ tag_name ++ ".html");
            b.getInstallStep().dependOn(&install_html.step);
            build_step.dependOn(&install_html.step);
        }

        // run
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("example-" ++ tag_name ++ "-run", "Run the " ++ tag_name ++ " example");
        run_step.dependOn(&run_cmd.step);

        // check that this example compiles, but skip llvm output that takes a while to run
        const exe_check = b.addExecutable(.{
            .name = tag_name,
            .root_source_file = b.path("examples/" ++ tag_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_check.root_module.addImport("seizer", module);
        exe_check.step.dependOn(generate_wayland_step);

        check_step.dependOn(&exe_check.step);
    }
}

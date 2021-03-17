# seizer

`seizer` is a Zig library for making games that target the desktop and browser.
It exposes an OpenGL ES 3.0 rendering context and cross platform file loading
functions.

## Features

-   [ ] Cross-platform windows and OpenGL ES 3.0
    -   [x] Web (Firefox, Chrome)
    -   [x] Linux
    -   [ ] Windows
    -   [ ] MacOS
-   [x] Cross platform file loading
    -   [x] Uses `fetch` to load files on the web
    -   [x] Loads assets from the CWD on desktop
-   Listening for Mouse/Keyboard Events
-   Main loop based on Gaffer on Games' [Fix Your Timestep!][]

[fix your timestep!]: https://www.gafferongames.com/post/fix_your_timestep/

## Usage

On any platform you want to build for, you need to add `seizer` as a
dependency.  You can do this by copying the repository into your project folder
or adding it using one of zig's unofficial package managers:

### zigmod

To add `seizer` as a dependency using [zigmod][], add the following to your `zig.mod`:

```yaml
dependencies:
    - type: git
      path: https://github.com/leroycep/seizer.git
```

Now run `zigmod fetch`.

[zigmod]: https://github.com/nektro/zigmod

### gyro

To add `seizer` as a dependency using [gyro][]:

```
gyro add --github leroycep/seizer
```

[gyro]: https://github.com/mattnite/gyro

after setting up your project's `build.zig` (see gyro docs), run

```
gyro build
```

to fetch dependencies and build your project.

### Desktop

`seizer` uses SDL2 to create a window and acquire an OpenGL context. In your
`build.zig`, make sure that "SDL2" is added as a dependency and that libc is
linked:

```zig
const Builder = @import("std").build.Builder;
const deps = @import("./deps.zig");

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const native = b.addExecutable("your-app-name-here", "path/to/main.zig");
    native.setTarget(target);
    native.setBuildMode(mode);

    // Link SDL2
    native.linkLibC();
    native.linkSystemLibrary("SDL2");

    // Add seizer and all other dependencies in `zig.mod` to the native target
    deps.addAllTo(native);
}
```

Than we can build and run the game like so:

```sh
$ zig build install
$ ./zig-cache/bin/your-app-name-here
```

Note: Building `seizer` for desktop platforms other than Linux hasn't been
tested. You may want to follow [these instructions][sdl-zig-example] to build
for other OSes.

[sdl-zig-example]: https://github.com/MasterQ32/SDL.zig-Example

### Web

There are a couple of things you need to do to run your `seizer` app in the
browser.

1. Compile your app as a static library for the `wasm32-freestanding` target
2. Copy the WASM binary to your webserver's `public` directory. I use
   `zig-cache/www` for development.
3. Copy `src/web/seizer.js` to your repository, and then have `build.zig` copy
   it to `zig-cache/www`.
4. Create an HTML file that loads the WASM binary and instantiates it (see the
   [`clear.html`][] example for more details). Then have `build.zig` copy it to
   `zig-cache/www`.
5. If you have any assets, make sure to copy to have `build.zig` copy them to
   `zig-cache/www`.

[`clear.html`]: ./examples/clear.html

A complete `build.zig` targeting web would look something like this:

```zig
const Builder = @import("std").build.Builder;
const deps = @import("./deps.zig");

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    // 1. Compile app for wasm32
    const web = b.addStaticLibrary("your-app-name-here-web", "path/to/main.zig");
    web.setBuildMode(mode);
    web.setTarget(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    
    // Add seizer and all other dependencies in `zig.mod` to the web target
    deps.addAllTo(native);
    
    // 2. Output the WASM binary to `zig-cache/www` when it is built
    web.setOutputDir(b.fmt("{s}/www", .{b.install_prefix}));
    
    // 3. Install `seizer.js` to "<prefix>/www". By default this means "zig-cache/www"
    const install_seizerjs = b.addInstallFile("./seizer.js", "www/seizer.js");

    // 4. Install `index.js` to "<prefix>/www". By default this means "zig-cache/www"
    const install_index = b.addInstallFile("index.html", "www/index.html");

    // 5. Install example assets to "<prefix>/www". By default this means "zig-cache/www"
    const install_assets_web = b.addInstallDirectory(.{
        .source_dir = "assets",
        .install_dir = .Prefix,
        .install_subdir = "www",
    });

    const build_web = b.step("example-" ++ example.name ++ "-web", "Build the " ++ example.name ++ " example for the web");
    build_web.dependOn(&web.step);
    build_web.dependOn(&install_seizerjs.step);
    build_web.dependOn(&install_index.step);
    build_web.dependOn(&install_assets_web.step);
}
```

## FAQ

> Why is it called "seizer"?

It is a reference to the "Seizer Beam" from the game [Zero Wing][]. Move Zig!

[zero wing]: https://en.wikipedia.org/wiki/Zero_Wing

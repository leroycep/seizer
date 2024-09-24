# seizer

`seizer` is a Zig library for making games and applications that target the desktop and browser.
It exposes an OpenGL ES 3.0 rendering context. It is currently in an alpha state, and the APIs
constantly break.

## Planned Features

-   [ ] Cross-platform Windowing
    -   [ ] Linux (Wayland only, X11 is not planned at the moment, sorry)
    -   [ ] Windows
    -   [ ] Web (Firefox, Chrome)
    -   [ ] MacOS
-   [ ] Input handling
    -   [ ] Gamepad
    -   [ ] Mouse
    -   [ ] Keyboard
    -   [ ] Touch
-   [ ] Hardware accelerated rendering
    -   [ ] 2d sprite based rendering
    -   [ ] shader effects
    -   [ ] Multiple backends
        -   [ ] WebGL 2.0/OpenGL ES 3.0
        -   [ ] DirectX
        -   [ ] Vulkan
-   [ ] a built-in by optional GUI library
-   [ ] specific device support
    -   [ ] Steam Deck
    -   [ ] Anbernic RG35XX H
    -   [ ] Anbernic RG351M
    -   [ ] Powkiddy RGB30

## FAQ

> How do I run the examples on NixOS?

Mostly included because NixOS is my daily driver OS.

First, [make you have OpenGL enabled](https://nixos.wiki/wiki/OpenGL).

Second, make sure that `libEGL` and `vulkan-loader` are available in `LD_LIBRARY_PATH`, [or `NIX_LD_LIBRARY_PATH` if you are using nix-ld](https://github.com/nix-community/nix-ld).

And third, run the examples with an explicit target. For example:

```
zig build example-clear-run -Dtarget=x86_64-linux-gnu
```

Without the above step, Zig will use the native target. When targeting native Zig will use dynamic loader specific to NixOS,
at some path like `/nix/store/r8qsxm85rlxzdac7988psm7gimg4dl3q-glibc-2.39-52/lib/ld-linux-x86-64.so.2`. Giving Zig the generic
target we tell it to use the standard location of the dynamic loader, `/usr/lib64/ld-linux-x86-64.so.2`.

You can also explicitly set the dynamic loader path:

```
zig build example-clear-run -Ddynamic-linker=/lib64/ld-linux-x86-64.so.2
```

> Why should I use `seizer` over SDL or GLFW?

You probably shouldn't, at the moment. I'm using it for the following reasons:

- I want to learn about low level details of the systems I'm deploying to!
- I prefer using Zig. While I can use SDL and GLFW from Zig, it means diving into C code if I'm trying to figure out why something isn't working.
- I use Wayland on Linux, and last I checked SDL2 and GLFW need to be configured to target Wayland instead of X11.
- I want my games to run on gaming handhelds like the Anbernic RG35XX H. This requires learning the low level details, and if I'm relying on GLFW or SDL2, I would be forced to use C and its build systems. Not to mention that GLFW doesn't support systems without a window manager, which is not uncommon on retro gaming handhelds.

But regardless of the personal insanity that drives me to make `seizer`, I would highly recommend [SDL2][] or [GLFW][]
if you need something that is `stable` and `works`.

> Why is it called "seizer"?

It is a reference to the "Seizer Beam" from the game [Zero Wing][]. Move Zig!

[zero wing]: https://en.wikipedia.org/wiki/Zero_Wing

## Inspiration

`seizer` doesn't exist in a void and there are many projects that have come before it. In fact, `seizer`
was originally a wrapper over [SDL2][], then over [GLFW][], and now is its own thing.

- [SDL2][]: A C library for windowing and obtaining a OpenGL context.
- [GLFW][]: A C library for windowing and obtaining a OpenGL context.
- [dvui][]: A zig immediate mode UI.
- [bgfx][]: It is not yet implemented, but I want to have a graphics abstraction similar to `bgfx`. OpenGL ES 3.0 is nice, but unless I want to spend time bundling [ANGLE][], it is not supported well on MacOS or Windows.

[dvui]: https://github.com/david-vanderson/dvui
[SDL2]: https://www.libsdl.org/
[GLFW]: https://www.glfw.org/
[bgfx]: https://github.com/bkaradzic/bgfx
[ANGLE]: https://github.com/google/angle

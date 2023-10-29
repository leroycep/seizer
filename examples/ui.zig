const store = seizer.ui.store;
const geom = seizer.geometry;
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;
const BitmapFont = seizer.font.Bitmap;
const NinePatch = seizer.ninepatch.NinePatch;
const Stage = seizer.ui.Stage;
const Observer = seizer.ui.Observer;
const Store = seizer.ui.store.Store;
const LayoutEngine = seizer.ui.LayoutEngine;
const Painter = seizer.ui.Painter;

const App = struct {
    gpa: std.mem.Allocator,
    window: *seizer.backend.glfw.c.GLFWwindow,
    canvas: seizer.Canvas,
    texture: seizer.Texture,
    stage: *seizer.ui.Stage,

    count: i64,
    counter_label: *seizer.ui.Label,

    pub fn new(gpa: std.mem.Allocator) !*App {
        var app = try gpa.create(App);
        errdefer gpa.destroy(app);

        seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_OPENGL_DEBUG_CONTEXT, seizer.backend.glfw.c.GLFW_TRUE);
        seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CLIENT_API, seizer.backend.glfw.c.GLFW_OPENGL_ES_API);
        seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MINOR, 0);

        //  Open window
        const window = seizer.backend.glfw.c.glfwCreateWindow(320, 240, "UI - Seizer", null, null) orelse return error.GlfwCreateWindow;
        errdefer seizer.backend.glfw.c.glfwDestroyWindow(window);

        seizer.backend.glfw.c.glfwMakeContextCurrent(window);

        gl_binding.init(seizer.backend.glfw.GlBindingLoader);
        gl.makeBindingCurrent(&gl_binding);

        // set up canvas for rendering
        var canvas = try seizer.Canvas.init(gpa, .{});
        errdefer canvas.deinit(gpa);

        // texture containing ui elements
        var texture = try Texture.initFromFileContents(gpa, @embedFile("assets/ui.png"), .{});
        errdefer texture.deinit();

        // NinePatches from the above texture
        const ninepatch_frame = seizer.NinePatch.initv(texture, .{ .pos = .{ 0, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 });
        const ninepatch_nameplate = seizer.NinePatch.initv(texture, .{ .pos = .{ 48, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 });
        const ninepatch_label = seizer.NinePatch.initv(texture, .{ .pos = .{ 96, 24 }, .size = .{ 12, 12 } }, .{ 4, 4 });
        const ninepatch_text_field = seizer.NinePatch.initv(texture, .{ .pos = .{ 96, 24 }, .size = .{ 12, 12 } }, .{ 4, 4 });
        const ninepatch_keyrest = seizer.NinePatch.initv(texture, .{ .pos = .{ 96, 0 }, .size = .{ 24, 24 } }, .{ 8, 8 });
        const ninepatch_keyup = seizer.NinePatch.initv(texture, .{ .pos = .{ 120, 24 }, .size = .{ 24, 24 } }, .{ 8, 8 });
        const ninepatch_keydown = seizer.NinePatch.initv(texture, .{ .pos = .{ 120, 0 }, .size = .{ 24, 24 } }, .{ 8, 8 });

        const stage = try Stage.init(gpa, seizer.ui.Style{
            .padding = .{ .min = .{ 0, 0 }, .max = .{ 0, 0 } },
            .text_font = &app.canvas.font,
            .text_scale = 2,
            .text_color = [4]u8{ 0, 0, 0, 0xFF },
            .background_image = seizer.NinePatch.initStretched(.{ .glTexture = canvas.blank_texture, .size = .{ 1, 1 } }, .{ .pos = .{ 0, 0 }, .size = .{ 1, 1 } }),
            .background_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        });
        errdefer stage.destroy();

        const default_text_field_style = stage.default_style.with(.{
            .padding = .{ .min = .{ 4, 4 }, .max = .{ 4, 4 } },
            .background_image = ninepatch_text_field,
            .background_color = [4]u8{ 0xC0, 0xC0, 0xC0, 0xFF },
        });
        const hovered_text_field_style = default_text_field_style.with(.{
            .background_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        });
        const focused_text_field_style = hovered_text_field_style.with(.{
            .background_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        });

        const centered = try seizer.ui.FlexBox.new(stage);
        defer centered.element.release();
        centered.justification = .center;
        centered.cross_align = .center;
        stage.setRoot(&centered.element);

        const frame = try seizer.ui.Frame.new(stage);
        defer frame.element.release();
        frame.style = stage.default_style.with(.{
            .padding = .{ .min = .{ 16, 16 }, .max = .{ 16, 16 } },
            .background_image = ninepatch_frame,
        });
        try centered.appendChild(&frame.element);

        const flexbox = try seizer.ui.FlexBox.new(stage);
        defer flexbox.element.release();
        flexbox.justification = .center;
        flexbox.cross_align = .center;
        flexbox.direction = .column;
        frame.setChild(&flexbox.element);

        // +---------------+
        // | Hello, world! |
        // +---------------+
        const nameplate = try seizer.ui.Label.new(stage, "Hello, world!");
        defer nameplate.element.release();
        nameplate.style = stage.default_style.with(.{
            .padding = .{ .min = .{ 16, 16 }, .max = .{ 16, 16 } },
            .background_image = ninepatch_nameplate,
        });
        try flexbox.appendChild(&nameplate.element);

        // +---+ +----+ +---+
        // | < | | 00 | | > |
        // +---+ +----+ +---+
        const counter_flexbox = try seizer.ui.FlexBox.new(stage);
        defer counter_flexbox.element.release();
        counter_flexbox.justification = .space_between;
        counter_flexbox.cross_align = .center;
        counter_flexbox.direction = .row;
        try flexbox.appendChild(&counter_flexbox.element);

        const decrement_button = try seizer.ui.Button.new(stage, "<");
        defer decrement_button.element.release();
        decrement_button.on_click = .{ .userdata = app, .callback = onDecrement };
        decrement_button.default_style = stage.default_style.with(.{
            .padding = .{ .min = .{ 8, 9 }, .max = .{ 8, 7 } },
            .background_image = ninepatch_keyrest,
        });
        decrement_button.hovered_style = stage.default_style.with(.{
            .padding = .{ .min = .{ 8, 8 }, .max = .{ 8, 8 } },
            .background_image = ninepatch_keyup,
        });
        decrement_button.clicked_style = stage.default_style.with(.{
            .padding = .{ .min = .{ 8, 10 }, .max = .{ 8, 5 } },
            .background_image = ninepatch_keydown,
        });
        try counter_flexbox.appendChild(&decrement_button.element);

        const counter_label_text = try gpa.dupe(u8, "0");
        const counter_label = try seizer.ui.Label.new(stage, counter_label_text);
        defer counter_label.element.release();
        counter_label.style = stage.default_style.with(.{
            .padding = .{ .min = .{ 4, 4 }, .max = .{ 4, 4 } },
            .background_image = ninepatch_label,
        });
        try counter_flexbox.appendChild(&counter_label.element);

        const increment_button = try seizer.ui.Button.new(stage, ">");
        defer increment_button.element.release();
        increment_button.on_click = .{ .userdata = app, .callback = onIncrement };
        increment_button.default_style = decrement_button.default_style;
        increment_button.hovered_style = decrement_button.hovered_style;
        increment_button.clicked_style = decrement_button.clicked_style;
        try counter_flexbox.appendChild(&increment_button.element);

        // +--------------+
        // | text input|  |
        // +--------------+
        const text_field = try seizer.ui.TextField.new(stage);
        defer text_field.element.release();
        text_field.default_style = default_text_field_style;
        text_field.hovered_style = hovered_text_field_style;
        text_field.focused_style = focused_text_field_style;
        try flexbox.appendChild(&text_field.element);

        // tell the counter_label that we are holding a reference to it in App
        counter_label.element.acquire();
        app.* = .{
            .gpa = gpa,
            .window = window,
            .texture = texture,
            .canvas = canvas,
            .stage = stage,

            .count = 0,
            .counter_label = counter_label,
        };

        // Set up input callbacks
        seizer.backend.glfw.c.glfwSetWindowUserPointer(window, app);

        _ = seizer.backend.glfw.c.glfwSetKeyCallback(window, &glfw_key_callback);
        _ = seizer.backend.glfw.c.glfwSetMouseButtonCallback(window, &glfw_mousebutton_callback);
        _ = seizer.backend.glfw.c.glfwSetCursorPosCallback(window, &glfw_cursor_pos_callback);
        _ = seizer.backend.glfw.c.glfwSetCharCallback(window, &glfw_char_callback);
        _ = seizer.backend.glfw.c.glfwSetScrollCallback(window, &glfw_scroll_callback);
        _ = seizer.backend.glfw.c.glfwSetWindowSizeCallback(window, &glfw_window_size_callback);
        _ = seizer.backend.glfw.c.glfwSetFramebufferSizeCallback(window, &glfw_framebuffer_size_callback);

        app.stage.needs_layout = true;

        return app;
    }

    pub fn destroy(app: *App) void {
        app.gpa.free(app.counter_label.text);
        app.counter_label.text = "";
        app.counter_label.element.release();
        app.stage.destroy();

        app.texture.deinit();
        app.canvas.deinit(app.gpa);
        seizer.backend.glfw.c.glfwDestroyWindow(app.window);
        app.gpa.destroy(app);
    }

    fn onIncrement(userdata: ?*anyopaque, button: *seizer.ui.Button) void {
        _ = button;
        const app: *App = @ptrCast(@alignCast(userdata.?));

        app.count += 1;

        const old_text = app.counter_label.text;
        const new_text = std.fmt.allocPrint(app.gpa, "{}", .{app.count}) catch return;

        app.counter_label.text = new_text;
        app.gpa.free(old_text);
        app.stage.needs_layout = true;
    }

    fn onDecrement(userdata: ?*anyopaque, button: *seizer.ui.Button) void {
        _ = button;
        const app: *App = @ptrCast(@alignCast(userdata.?));

        app.count -= 1;

        const old_text = app.counter_label.text;
        const new_text = std.fmt.allocPrint(app.gpa, "{}", .{app.count}) catch return;

        app.counter_label.text = new_text;
        app.gpa.free(old_text);
        app.stage.needs_layout = true;
    }
};

var gl_binding: gl.Binding = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa.allocator());

    _ = seizer.backend.glfw.c.glfwSetErrorCallback(&seizer.backend.glfw.defaultErrorCallback);

    const glfw_init_res = seizer.backend.glfw.c.glfwInit();
    if (glfw_init_res != 1) {
        std.debug.print("glfw init error: {}\n", .{glfw_init_res});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.c.glfwTerminate();

    const app = try App.new(gpa.allocator());
    defer app.destroy();

    while (seizer.backend.glfw.c.glfwWindowShouldClose(app.window) != seizer.backend.glfw.c.GLFW_TRUE) {
        seizer.backend.glfw.c.glfwPollEvents();

        gl.clearColor(0.7, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        var window_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetWindowSize(app.window, &window_size[0], &window_size[1]);

        var framebuffer_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetFramebufferSize(app.window, &framebuffer_size[0], &framebuffer_size[1]);

        app.canvas.begin(.{
            .window_size = [2]f32{
                @floatFromInt(window_size[0]),
                @floatFromInt(window_size[1]),
            },
            .framebuffer_size = [2]f32{
                @floatFromInt(framebuffer_size[0]),
                @floatFromInt(framebuffer_size[1]),
            },
        });
        app.stage.render(&app.canvas, [2]f32{
            @floatFromInt(window_size[0]),
            @floatFromInt(window_size[1]),
        });
        app.canvas.end();

        seizer.backend.glfw.c.glfwSwapBuffers(app.window);
    }
}

fn glfw_key_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));

    const key_event = seizer.ui.event.Key{
        .key = @enumFromInt(key),
        .scancode = scancode,
        .action = @enumFromInt(action),
        .mods = .{
            .shift = seizer.backend.glfw.c.GLFW_MOD_SHIFT == seizer.backend.glfw.c.GLFW_MOD_SHIFT & mods,
            .control = seizer.backend.glfw.c.GLFW_MOD_CONTROL == seizer.backend.glfw.c.GLFW_MOD_CONTROL & mods,
            .alt = seizer.backend.glfw.c.GLFW_MOD_ALT == seizer.backend.glfw.c.GLFW_MOD_ALT & mods,
            .super = seizer.backend.glfw.c.GLFW_MOD_SUPER == seizer.backend.glfw.c.GLFW_MOD_SUPER & mods,
            .caps_lock = seizer.backend.glfw.c.GLFW_MOD_CAPS_LOCK == seizer.backend.glfw.c.GLFW_MOD_CAPS_LOCK & mods,
            .num_lock = seizer.backend.glfw.c.GLFW_MOD_NUM_LOCK == seizer.backend.glfw.c.GLFW_MOD_NUM_LOCK & mods,
        },
    };

    if (app.stage.onKey(key_event)) {
        return;
    }
}

fn glfw_mousebutton_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = mods;
    const app = @as(*App, @ptrCast(@alignCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));

    check_ui: {
        var mouse_pos_f64: [2]f64 = undefined;
        seizer.backend.glfw.c.glfwGetCursorPos(window, &mouse_pos_f64[0], &mouse_pos_f64[1]);
        const mouse_pos = [2]f32{
            @floatCast(mouse_pos_f64[0]),
            @floatCast(mouse_pos_f64[1]),
        };

        const click_event = seizer.ui.event.Click{
            .pos = mouse_pos,
            .button = switch (button) {
                seizer.backend.glfw.c.GLFW_MOUSE_BUTTON_LEFT => .left,
                seizer.backend.glfw.c.GLFW_MOUSE_BUTTON_RIGHT => .right,
                seizer.backend.glfw.c.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
                else => break :check_ui,
            },
            .pressed = action == seizer.backend.glfw.c.GLFW_PRESS,
        };

        if (app.stage.onClick(click_event)) {
            return;
        }
    }
}

fn glfw_cursor_pos_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));

    const mouse_pos = [2]f32{ @floatCast(xpos), @floatCast(ypos) };

    if (app.stage.onHover(mouse_pos)) {
        return;
    }
}

fn glfw_scroll_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
    const app = @as(*App, @ptrCast(@alignCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));

    const scroll_event = seizer.ui.event.Scroll{
        .offset = [2]f32{
            @floatCast(xoffset),
            @floatCast(yoffset),
        },
    };

    if (app.stage.onScroll(scroll_event)) {
        return;
    }
}

fn glfw_char_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, codepoint: c_uint) callconv(.C) void {
    const app = @as(*App, @alignCast(@ptrCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));

    var text_input_event = seizer.ui.event.TextInput{ .text = .{} };
    const codepoint_len = std.unicode.utf8Encode(@as(u21, @intCast(codepoint)), &text_input_event.text.buffer) catch return;
    text_input_event.text.resize(codepoint_len) catch unreachable;

    if (app.stage.onTextInput(text_input_event)) {
        return;
    }
}

fn glfw_window_size_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const app = @as(*App, @alignCast(@ptrCast(seizer.backend.glfw.c.glfwGetWindowUserPointer(window))));
    _ = width;
    _ = height;
    app.stage.needs_layout = true;
}

fn glfw_framebuffer_size_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    _ = window;
    gl.viewport(
        0,
        0,
        @intCast(width),
        @intCast(height),
    );
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;
var tracer: ?otel.api.trace.Tracer = null;

pub fn init() !void {
    tracer = otel.api.trace.getTracer(.{ .name = "xyz.geemili.seizer.examples.clear" });

    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Clear - Seizer Example",
        .app_name = "xyz.geemili.seizer.examples.clear",
        .on_event = onWindowEvent,
        .on_render = render,
        .size = .{ 640, 480 },
    });

    seizer.platform.setDeinitCallback(deinit);
}

fn deinit() void {
    if (swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    display.destroyWindow(window_global);
    gfx.destroy();
    display.destroy();

    tracer_provider.?.shutdown();
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    _ = window;
    switch (event) {
        .should_close => seizer.platform.setShouldExit(true),
        .resize, .rescale => if (swapchain_opt) |swapchain| {
            gfx.destroySwapchain(swapchain);
            swapchain_opt = null;
        },
        .input => |_| {},
    }
}

fn render(window: *seizer.Display.Window) !void {
    const render_span = tracer.?.createSpan("render", null, .{});
    defer render_span.end(null);
    const render_context = otel.api.trace.contextWithSpan(otel.api.Context.current(), render_span);
    const attach_token = render_context.attach();
    defer _ = render_context.detach(attach_token);

    const window_size = display.windowGetSize(window);
    const window_scale = display.windowGetScale(window);

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size, .scale = window_scale });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    gfx.beginRendering(render_buffer, .{
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });
    gfx.endRendering(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

pub const opentelemetry_options: otel.api.Options = .{
    .tracer_provider = getTracer,
    .context_extract_span = otel.trace.DynamicTracerProvider.contextExtractSpan,
    .context_with_span = otel.trace.DynamicTracerProvider.contextWithSpan,
};

const tracer_provider_resource = otel.Resource.initStatic("xyz.geemili.seizer.examples.clear");
var tracer_provider: ?*otel.trace.DynamicTracerProvider = null;
fn getTracer(comptime scope: otel.api.InstrumentationScope) otel.api.trace.Tracer {
    if (tracer_provider == null) {
        const otlp_exporter = otel.exporter.OpenTelemetry.create(seizer.platform.allocator(), .{}) catch return otel.api.trace.Tracer.NULL;
        const batching_span_processor = otel.trace.SpanProcessor.Batching.create(seizer.platform.allocator(), otlp_exporter.spanExporter(), .{}) catch return otel.api.trace.Tracer.NULL;

        tracer_provider = otel.trace.DynamicTracerProvider.init(seizer.platform.allocator(), .{
            .resource = tracer_provider_resource,
            .span_processors = &.{batching_span_processor.spanProcessor()},
        }) catch |err| std.debug.panic("failed to initialize tracer provider: {}", .{err});
    }
    return tracer_provider.?.getTracer(scope);
}

const otel = @import("opentelemetry");
const seizer = @import("seizer");
const std = @import("std");

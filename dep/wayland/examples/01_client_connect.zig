const std = @import("std");
const wayland = @import("wayland");

const Globals = struct {
    compositor: ?*wayland.core.Compositor = null,
    xdg_wm_base: ?*wayland.xdg_shell.xdg_wm_base = null,
};

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    const display_path = try wayland.getDisplayPath(gpa);
    defer gpa.free(display_path);

    var conn = try wayland.Conn.init(gpa, display_path);
    defer conn.deinit();

    var globals = Globals{};
    const registry = try conn.getRegistry();
    registry.userdata = &globals;
    registry.on_event = onRegistryEvent;

    try conn.dispatchUntilSync();

    const surface = try globals.compositor.?.create_surface();

    const xdg_surface = try globals.xdg_wm_base.?.get_xdg_surface(surface);
    xdg_surface.on_event = onXdgSurfaceEvent;

    const xdg_toplevel = try xdg_surface.get_toplevel();

    try surface.commit();

    try conn.dispatchUntilSync();

    _ = xdg_toplevel;
}

fn onRegistryEvent(registry: *wayland.core.Registry, userdata: ?*anyopaque, event: wayland.core.Registry.Event) void {
    const globals: *Globals = @ptrCast(@alignCast(userdata));
    switch (event) {
        .global => |global| {
            std.log.debug("{s}:{} global {} = {s} v{}", .{ @src().file, @src().line, global.name, global.interface, global.version });
            if (std.mem.eql(u8, global.interface, wayland.core.Compositor.INTERFACE.name) and global.version >= wayland.core.Compositor.INTERFACE.version) {
                globals.compositor = registry.bind(wayland.core.Compositor, global.name) catch return;
            } else if (std.mem.eql(u8, global.interface, wayland.xdg_shell.xdg_wm_base.INTERFACE.name) and global.version >= wayland.xdg_shell.xdg_wm_base.INTERFACE.version) {
                globals.xdg_wm_base = registry.bind(wayland.xdg_shell.xdg_wm_base, global.name) catch return;
            }
        },
        .global_remove => {},
    }
}

fn onXdgSurfaceEvent(xdg_surface: *wayland.xdg_shell.xdg_surface, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_surface.Event) void {
    _ = userdata;
    switch (event) {
        .configure => |conf| {
            xdg_surface.ack_configure(conf.serial) catch |e| {
                std.log.warn("Failed to ack configure: {}", .{e});
            };
        },
    }
}

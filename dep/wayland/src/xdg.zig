pub const WmBase = struct {
    pub const INTERFACE = "xdg_wm_base";
    pub const VERSION = 2;

    pub const Request = union(Request.Tag) {
        destroy: void,
        create_positioner: struct {
            id: u32,
        },
        get_xdg_surface: struct {
            id: u32,
            surface: u32,
        },
        pong: struct {
            serial: u32,
        },

        pub const Tag = enum(u16) {
            destroy,
            create_positioner,
            get_xdg_surface,
            pong,
        };
    };

    pub const Event = union(Event.Tag) {
        ping: struct { serial: u32 },

        pub const Tag = enum(u16) {
            ping,
        };
    };

    pub const Error = enum(u32) {
        role,
        defunct_surfaces,
        not_the_topmost_popup,
        invalid_popup_parent,
        invalid_surface_state,
        invalid_positioner,
        unresponsive,
    };
};

pub const Surface = struct {
    pub const Request = union(enum) {
        destroy: void,
        get_toplevel: struct {
            id: u32,
        },
        get_popup: struct {
            id: u32,
            /// Allows null
            parent: u32,
            positioner: u32,
        },
        set_window_geometry: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        ack_configure: struct {
            serial: u32,
        },
    };

    pub const Event = union(enum) {
        configure: struct { serial: u32 },
    };

    pub const Error = enum(u32) {
        not_constructed = 1,
        already_constructed,
        unconfigured_buffer,
        invalid_serial,
        invalid_size,
        defunct_role_object,
    };
};

pub const Toplevel = struct {
    pub const Request = union(enum) {
        destroy: void,
        set_parent: struct {
            /// Allows null
            parent: u32,
        },
        set_title: struct {
            title: []const u8,
        },
        set_app_id: struct {
            app_id: []const u8,
        },
        show_window_menu: struct {
            seat: u32,
            serial: u32,
            x: i32,
            y: i32,
        },
        move: struct {
            seat: u32,
            serial: u32,
        },
        resize: struct {
            seat: u32,
            serial: u32,
            edges: Toplevel.ResizeEdge,
        },
    };

    pub const Event = union(enum) {
        configure: struct {
            width: i32,
            height: i32,
            states: []const Toplevel.State,
        },
        close: void,
        configure_bounds: struct {
            width: i32,
            height: i32,
        },
        wm_capabilities: struct {
            capabilities: []const Toplevel.WmCapabilities,
        },
    };

    pub const ResizeEdge = enum(u32) {
        none,
        top,
        bottom,
        left,
        top_left,
        bottom_left,
        right,
        top_right,
        bottom_right,
        _,
    };

    pub const State = enum(u32) {
        maximized,
        fullscreen,
        resizing,
        activated,
        tiled_left,
        tiled_right,
        tiled_top,
        tiled_bottom,
        suspended,
        _,
    };

    pub const WmCapabilities = enum(u32) {
        window_menu,
        maximize,
        fullscreen,
        minimize,
        _,
    };

    pub const Error = enum(u32) {
        not_constructed = 1,
        already_constructed,
        unconfigured_buffer,
        invalid_serial,
        invalid_size,
        defunct_role_object,
        _,
    };
};

pub const DecorationManagerV1 = struct {
    pub const INTERFACE = "zxdg_decoration_manager_v1";
    pub const VERSION = 1;

    pub const Request = union(Request.Tag) {
        destroy: void,
        get_toplevel_decoration: struct {
            new_id: u32,
            toplevel: u32,
        },

        pub const Tag = enum(u16) {
            destroy,
            get_toplevel_decoration,
        };
    };
};

pub const ToplevelDecorationV1 = struct {
    pub const Request = union(Request.Tag) {
        destroy: void,
        unset_mode: void,
        set_mode: struct {
            mode: Mode,
        },

        pub const Tag = enum(u16) {
            destroy,
            unset_mode,
            set_mode,
        };
    };

    pub const Event = union(Event.Tag) {
        configure: struct { mode: Mode },

        pub const Tag = enum(u16) {
            configure,
        };
    };

    pub const Error = enum(u32) {
        unconfigured_buffer,
        already_constructed,
        orphaned,
    };

    pub const Mode = enum(u32) {
        client_side = 1,
        server_side = 2,
    };
};

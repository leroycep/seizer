pub const TextInputManagerV3 = struct {
    pub const INTERFACE = "zwp_text_input_manager_v3";
    pub const VERSION = 1;

    pub const Request = union(Request.Tag) {
        destroy: void,
        get_text_input: struct {
            id: u32,
            seat: u32,
        },
        pub const Tag = enum(u16) {
            destroy,
            get_text_input,
        };
    };
};

pub const TextInputV3 = struct {
    pub const Request = union(Tag) {
        destroy,
        enable,
        disable,
        set_surrounding_text: struct {
            text: []const u8,
            cursor: i32,
            anchor: i32,
        },
        set_text_change_cause: struct {
            cause: ChangeCause,
        },
        set_content_type: struct {
            hint: ContentHint,
            purpose: ContentPurpose,
        },
        set_cursor_rectangle: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        commit,
        pub const Tag = enum(u16) {
            destroy,
            enable,
            disable,
            set_surrounding_text,
            set_text_change_cause,
            set_content_type,
            set_cursor_rectangle,
            commit,
        };
    };

    pub const Event = union(Tag) {
        enter: struct { surface: u32 },
        leave: struct { surface: u32 },
        preedit_string: struct {
            text: ?[]const u8,
            cursor_begin: i32,
            cursor_end: i32,
        },
        commit_string: struct {
            text: []const u8,
        },
        delete_surrounding_text: struct {
            before_length: usize,
            after_length: usize,
        },
        done: struct {
            serial: u32,
        },
        pub const Tag = enum {
            enter,
            leave,
            preedit_string,
            commit_string,
            delete_surrounding_text,
            done,
        };
    };

    pub const ChangeCause = enum(u32) {
        input_method,
        other,
    };

    pub const ContentHint = enum(u32) {
        none,
        completion,
        spellcheck,
        auto_capitalization,
        lowercase,
        uppercase,
        titlecase,
        hidden_text,
        sensitive_data,
        latin,
        multiline,
    };

    pub const ContentPurpose = enum(u32) {
        normal,
        alpha,
        digits,
        number,
        phone,
        url,
        email,
        name,
        password,
        pin,
        date,
        time,
        datetime,
        terminal,
    };
};

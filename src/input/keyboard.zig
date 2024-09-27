/// The value of a key pressed by the user, taking modifier keys (e.g. `Shift`),
/// keyboard locale, and keyboard layout into account.
///
/// Similar to `xkb.Symbol`.
///
/// https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values
pub const Key = union(enum) {
    unidentified,
    /// The key has a printable unicode value.
    unicode: u21,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#modifier_keys

    alt,
    alt_graph,
    caps_lock,
    control,
    @"fn",
    fn_lock,
    hyper,
    meta,
    num_lock,
    scroll_lock,
    shift,
    super,
    symbol,
    symbol_lock,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#whitespace_keys

    enter,
    tab,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#navigation_keys

    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,
    end,
    home,
    page_down,
    page_up,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#editing_keys

    backspace,
    clear,
    copy,
    /// The Cursor Select key
    cr_sel,
    cut,
    delete,
    erase_eof,
    /// The Extend Selection key
    ex_sel,
    insert,
    paste,
    redo,
    undo,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#function_keys

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,

    /// The first general-purpose virtual function key.
    soft1,
    /// The second general-purpose virtual function key.
    soft2,
    /// The third general-purpose virtual function key.
    soft3,
    /// The fourth general-purpose virtual function key.
    soft4,

    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_key_values#ui_keys

    accept,
    again,
    attn,
    cancel,
    context_menu,
    escape,
    execute,
    find,
    finish,
    help,
    /// Pauses the application or state, if applicable.
    ///
    /// Note: Not to be confused with `media_pause`.
    pause,
    /// Resumes a previously paused application, if applicable.
    ///
    /// Note: Not to be confused with `media_play`.
    play,
    props,
    select,
    zoom_in,
    zoom_out,
};

/// Similar to the Linux kernel's EvDev `KEY` values.
///
/// https://www.w3.org/TR/uievents-code/
pub const Scancode = enum {

    // https://www.w3.org/TR/uievents-code/#key-alphanumeric-writing-system

    /// `\`~` on a US keyboard
    backquote,
    /// `\|` on a US keyboard
    backslash,
    /// `[{` on a US keyboard
    bracket_left,
    /// `]}` on a US keyboard
    bracket_right,
    /// `,<` on a US keyboard
    comma,
    /// `0)` on a US keyboard
    @"0",
    /// `1!` on a US keyboard
    @"1",
    /// `2@` on a US keyboard
    @"2",
    /// `3#` on a US keyboard
    @"3",
    /// `4$` on a US keyboard
    @"4",
    /// `5%` on a US keyboard
    @"5",
    /// `6^` on a US keyboard
    @"6",
    /// `7&` on a US keyboard
    @"7",
    /// `8*` on a US keyboard
    @"8",
    /// `9(` on a US keyboard
    @"9",
    /// `=+` on a US keyboard
    equal,

    /// Located between the left `Shift` and `Z` keys. Labelled `\|` on a UK keyboard.
    intl_backslash,
    /// Located between the `/` and right `Shift` keys. Labelled `\ろ` (ro) on a Japanese keyboard.
    intl_ro,
    /// Located between the `=` and `Backspace` keys. Labelled `¥` (yen) on a Japanese keyboard. `\/` on a Russian keyboard.
    intl_yen,

    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,

    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,

    z,
    x,
    c,
    v,
    b,
    n,
    m,

    /// `-_` on a US keyboard
    minus,
    period,
    quote,
    semicolon,
    /// `/?` on a US keyboard
    slash,

    // https://www.w3.org/TR/uievents-code/#key-alphanumeric-functional

    alt_left,
    alt_right,
    backspace,
    caps_lock,
    context_menu,
    control_left,
    control_right,
    enter,
    meta_left,
    meta_right,
    shift_left,
    shift_right,
    space,
    tab,

    convert,
    kana_mode,
    lang1,
    lang2,
    lang3,
    lang4,
    lang5,
    non_convert,

    // https://www.w3.org/TR/uievents-code/#key-controlpad-section

    delete,
    end,
    help,
    home,
    insert,
    page_down,
    page_up,

    // https://www.w3.org/TR/uievents-code/#key-arrowpad-section

    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,

    // https://www.w3.org/TR/uievents-code/#key-numpad-section

    num_lock,
    numpad0,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    numpad_add,
    numpad_backspace,
    numpad_clear,
    numpad_clear_entry,
    numpad_comma,
    numpad_decimal,
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_hash,
    numpad_memory_add,
    numpad_memory_clear,
    numpad_memory_recall,
    numpad_memory_store,
    numpad_memory_subtract,
    numpad_multiply,
    numpad_paren_left,
    numpad_paren_right,
    numpad_star,
    numpad_subtract,

    // https://www.w3.org/TR/uievents-code/#key-function-section

    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    @"fn",
    fn_lock,
    print_screen,
    scroll_lock,
    pause,

    // https://www.w3.org/TR/uievents-code/#key-media

    browser_back,
    browser_favorites,
    browser_forward,
    browser_home,
    browser_refresh,
    browser_search,
    browser_stop,
    eject,
    launch_app1,
    launch_app2,
    launch_mail,
    media_play_pause,
    media_select,
    media_stop,
    media_track_next,
    media_track_previous,
    power,
    sleep,
    audio_volume_down,
    audio_volume_mute,
    audio_volume_up,
    wake_up,
};

pub const Action = enum {
    press,
    repeat,
    release,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

const std = @import("std");

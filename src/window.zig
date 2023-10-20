const kc = @import("input/keycode.zig");

pub const WindowEventTag = enum {
    RESIZED,
    EVENTS_CLEARED,
    KEY_DOWN,
    KEY_REPEAT,
    KEY_UP,
    CHAR,
};

pub const WindowEvent = union(WindowEventTag) {
    RESIZED: void,
    EVENTS_CLEARED: void,
    KEY_DOWN: KeyEvent,
    KEY_REPEAT: KeyEvent,
    KEY_UP: KeyEvent,
    CHAR: CharEvent,
};

pub const KeyEvent = struct {
    keycode: kc.KeyCode,
    repeat_count: u16,
    scan_code: u16,
};

pub const CharEvent = struct {
    utf32_char_code: u32,
    repeat_count: u16,
    scan_code: u16,
};

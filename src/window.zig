const kc = @import("input/keycode.zig");

pub const WindowEventTag = enum {
    RESIZED,
    EVENTS_CLEARED,
    LOST_FOCUS,
    GAINED_FOCUS,
    KEY_DOWN,
    KEY_REPEAT,
    KEY_UP,
    CHAR,
    CURSOR_MOVED,
    RAW_MOUSE_MOVED,
};

pub const WindowEvent = union(WindowEventTag) {
    RESIZED: WindowSize,
    EVENTS_CLEARED: void,
    LOST_FOCUS: void,
    GAINED_FOCUS: void,
    KEY_DOWN: KeyEvent,
    KEY_REPEAT: KeyEvent,
    KEY_UP: KeyEvent,
    CHAR: CharEvent,
    CURSOR_MOVED: CursorMoveEvent,
    RAW_MOUSE_MOVED: RawMouseMoveEvent,
};

pub const WindowSize = struct {
    width: i32,
    height: i32,
};

pub const KeyEvent = struct {
    keycode: kc.KeyCode,
    repeat_count: u16,
    scan_code: u16,
};

pub const CharEvent = struct {
    utf8_char_seq: [2:0]u8,
    utf8_char_len: usize,
    repeat_count: u16,
    scan_code: u16,
};

pub const CursorMoveEvent = struct {
    x_coord: i32,
    y_coord: i32,
};

pub const RawMouseMoveEvent = struct {
    x_delta: i32,
    y_delta: i32,
};

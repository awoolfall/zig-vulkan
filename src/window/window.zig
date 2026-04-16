const std = @import("std");
const eng = @import("self");
const builtin = @import("builtin");
pub const os = builtin.os;

pub const Window = switch (builtin.os.tag) {
    .windows => @import("platform/windows/windows.zig").Win32Window,
    else => @compileError("Unsupported OS"),
};

pub const WindowEvent = union(enum) {
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

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const WindowSize = struct {
    width: i32,
    height: i32,
};

pub const KeyEvent = struct {
    keycode: eng.input.KeyCode,
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

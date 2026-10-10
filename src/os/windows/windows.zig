const std = @import("std");
const eng = @import("self");
const os = @import("../os.zig");
const w32 = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("combaseapi.h");
    @cInclude("shellapi.h");
    @cInclude("dwmapi.h");
});

const __c = @import("windows_keycode.zig");
const convert_windows_keycode = __c.convert_windows_keycode;

var g_window_thread_id: w32.DWORD = undefined;
var g_window_thread_ready: std.Thread.ResetEvent = .{};

const MAX_G_MESSAGE_QUEUE = 1024;
var g_message_queue: [MAX_G_MESSAGE_QUEUE]os.WindowEvent = undefined;
var g_message_queue_pull_idx: usize = 0;
var g_message_queue_push_idx: usize = 0;
var g_message_queue_mutex = std.Thread.Mutex{};
fn push_window_event_to_queue(event: os.WindowEvent) void {
    g_message_queue_mutex.lock();
    defer g_message_queue_mutex.unlock();

    g_message_queue[g_message_queue_push_idx] = event;
    g_message_queue_push_idx += 1;
    if (g_message_queue_push_idx >= MAX_G_MESSAGE_QUEUE) {
        g_message_queue_push_idx = 0;
    }
}
fn pop_window_event_from_queue() ?os.WindowEvent {
    g_message_queue_mutex.lock();
    defer g_message_queue_mutex.unlock();

    if (g_message_queue_push_idx == g_message_queue_pull_idx) {
        return null;
    } else {
        const event = g_message_queue[g_message_queue_pull_idx];
        g_message_queue_pull_idx += 1;
        if (g_message_queue_pull_idx >= MAX_G_MESSAGE_QUEUE) {
            g_message_queue_pull_idx = 0;
        }
        return event;
    }
}

const WM_USER_REQUEST_CREATE_WINDOW = w32.WM_USER + 1;
const WM_USER_REQUEST_DESTROY_WINDOW = w32.WM_USER + 2;
const WM_USER_SHOW_CURSOR = w32.WM_USER + 3;

const MAX_WINDOWS = 32;

pub const WindowsPlatform = struct {
    pub const Window = WindowHandle;

    hInstance: w32.HINSTANCE,
    window_thread: std.Thread,
    window_thread_id: w32.DWORD,

    window_thread_hwnd_map: [MAX_WINDOWS]?w32.HWND = [1]?w32.HWND{null} ** MAX_WINDOWS,

    pub fn deinit(self: *WindowsPlatform) void {
        _ = self;
        w32.CoUninitialize();
    }

    pub fn init() !WindowsPlatform {
        g_window_thread_ready.reset();
        const window_thread = try std.Thread.spawn(.{}, window_thread_fn, .{});
        g_window_thread_ready.wait();

        _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
        errdefer w32.CoUninitialize();

        if (w32.SetProcessDPIAware() != w32.TRUE) {
            std.log.warn("Failed to set window DPI awareness", .{});
        }

        const hInstance: w32.HINSTANCE = @ptrCast(w32.GetModuleHandleA(null));
        if (hInstance == null) {
            std.log.err("Unable to get windows module handle: {}", .{w32.GetLastError()});
            return error.UnableToGetHInstance;
        }

        return WindowsPlatform {
            .hInstance = hInstance,
            .window_thread = window_thread,
            .window_thread_id = g_window_thread_id,
        };
    }

    fn find_hwnd_id(self: *const WindowsPlatform, hwnd: w32.HWND) ?usize {
        for (0..MAX_WINDOWS) |id| {
            if (self.window_thread_hwnd_map[id]) |id_hwnd| {
                if (hwnd == id_hwnd) {
                    return id;
                }
            }
        } else {
            return null;
        }
    }

    pub fn pull_event(self: *WindowsPlatform) !os.WindowEvent {
        _ = self;
        if (pop_window_event_from_queue()) |window_event| {
            return window_event;
        } else {
            return os.WindowEvent { .EVENTS_CLEARED = {} };
        }
    }

    pub fn create_new_window(self: *WindowsPlatform, window_id: u32, window_type: u32) !void {
        _ = w32.PostThreadMessageA(self.window_thread_id, WM_USER_REQUEST_CREATE_WINDOW, @intCast(window_type), @intCast(window_id));
    }

    pub fn show_cursor(self: *WindowsPlatform, should_show_cursor: bool) void {
        _ = w32.PostThreadMessageA(self.window_thread_id, WM_USER_SHOW_CURSOR, @intFromBool(should_show_cursor), 0);
    }

    pub fn free_confined_cursor(self: *WindowsPlatform) void {
        _ = self;
        _ = w32.ClipCursor(null);
    }

    pub fn confine_cursor(self: *WindowsPlatform, rect: os.Rect) void {
        _ = self;
        const w32rect = w32.RECT {
            .left = rect.x,
            .right = rect.x + rect.width,
            .top = rect.y,
            .bottom = rect.y + rect.height,
        };
        _ = w32.ClipCursor(&w32rect);
    }
    
    pub fn confine_cursor_to_current_pos(self: *WindowsPlatform) void {
        var cursor_pos: w32.POINT = undefined;
        if (w32.GetCursorPos(&cursor_pos) == 0) { return; }
        self.confine_cursor(os.Rect{
            .x = cursor_pos.x,
            .y = cursor_pos.y,
            .width = 1,
            .height = 1,
        });
    }
};

fn create_window(id: u32, options: struct {
    title: [*c]const u8 = "Window Made with Zig",
    width: u32 = 1920,
    height: u32 = 1080,
    raw_mouse_input: bool = false,
}) !void {
    const hInstance = w32.GetModuleHandleA(null);

    // width and height is what we want client rect to be 
    // CreateWindowExA takes in absolute height and width including title bar and border
    // Convert using AdjustWindowRectEx then pass rect into CreateWindowExA
    var rect = w32.RECT {
        .left = 0,
        .right = @intCast(options.width),
        .top = 0,
        .bottom = @intCast(options.height),
    };
    std.debug.assert(w32.AdjustWindowRectEx(
        &rect,
        w32.WS_OVERLAPPEDWINDOW,
        0,
        0
    ) != 0);

    const window_style: u32 = 
        @as(u32, @intCast(w32.WS_OVERLAPPEDWINDOW));

    const hwnd = w32.CreateWindowExA(
        0, 
        "Zig Engine Window Class", 
        options.title,
        window_style + w32.WS_VISIBLE,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT, 
        rect.right - rect.left, rect.bottom - rect.top, 
        null, null,
        hInstance,
        null) orelse {
            const err = w32.GetLastError();
            std.log.err("Unable to create windows window: {}", .{err});
            return error.UnableToCreateWindow;
        };

    const set_value: w32.BOOL = w32.TRUE;
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, &set_value, @sizeOf(w32.BOOL));

    if (!register_mouse_for_raw_input(hwnd)) {
        std.log.warn("Failed to get raw mouse input..", .{});
    }

    w32.DragAcceptFiles(hwnd, w32.TRUE);

    push_window_event_to_queue(os.WindowEvent { .WINDOW_CREATED = .{
        .id = id,
        .window = WindowHandle {
            .id = id,
            .hwnd = hwnd,
        },
    } });

    std.debug.assert(eng.get().os.window_thread_hwnd_map[id] == null);
    eng.get().os.window_thread_hwnd_map[id] = hwnd;
}

fn window_thread_fn() void {
    g_window_thread_id = w32.GetCurrentThreadId();
    g_window_thread_ready.set();

    const hInstance = w32.GetModuleHandleA(null);
    var wc = w32.WNDCLASSEXA{
        .lpfnWndProc = window_proc,
        .hInstance = hInstance,
        .lpszClassName = "Zig Engine Window Class",
        .style = 0,
        .hIcon = null,
        .hCursor = w32.LoadCursorA(null, @as(w32.LPCSTR, @ptrFromInt(32512))), // default arrow
        .hbrBackground = null,
        .lpszMenuName = null,
        .hIconSm = null,
        .cbClsExtra = 0,
        .cbSize = @sizeOf(w32.WNDCLASSEXA),
        .cbWndExtra = 0,
    };
    const class_atom = w32.RegisterClassExA(&wc);
    if (class_atom == 0) {
        std.log.err("Unable to register windows window class: {}", .{w32.GetLastError()});
    }
    
    var msg: w32.MSG = undefined;
    while (w32.GetMessageA(&msg, null, 0, 0) != 0) {
        // Intercept thread-specific requests before they hit DispatchMessage
        if (msg.hwnd == null) {
            switch (msg.message) {
                WM_USER_REQUEST_CREATE_WINDOW => {
                    const win_type: u32 = @intCast(msg.wParam);
                    const win_id: u32 = @intCast(msg.lParam);
                    _ = win_type;

                    create_window(win_id, .{ .raw_mouse_input = true, }) catch {};
                    continue; // Skip Translate/Dispatch
                },
                WM_USER_REQUEST_DESTROY_WINDOW => {
                    const id = msg.wParam;
                    if (eng.get().os.window_thread_hwnd_map[id]) |hwnd| {
                        _ = w32.DestroyWindow(hwnd);
                    } else {
                        std.log.err("Attempted to destroy unknown window id {}", .{id});
                    }
                },
                WM_USER_SHOW_CURSOR => {
                    const should_show_cursor = (msg.wParam != 0);
                    // Windows shows the cursor if an internal counter is greater than or
                    // equal to 0 and hides it if it is less than 0. The value of this counter
                    // is returned each ShowCursor(). To make sure this function behaves properly
                    // we need to manage this internal counter with while loops.
                    if (should_show_cursor) {
                        while (w32.ShowCursor(1) < 0) {}
                    } else {
                        while (w32.ShowCursor(0) >= 0) {}
                    }
                },
                else => {}
            }
        }

        if (msg.message >= w32.WM_KEYFIRST and msg.message <= w32.WM_KEYLAST) {
            _ = w32.TranslateMessage(&msg);
        }
        _ = w32.DispatchMessageA(&msg);
    }
}

pub const WindowHandle = struct {
    id: u32,
    hwnd: w32.HWND,

    pub fn close_window(self: *const WindowHandle) void {
        _ = w32.PostThreadMessageA(eng.get().os.window_thread_id, WM_USER_REQUEST_DESTROY_WINDOW, @intCast(self.id), 0);
    }

    pub fn get_client_size(self: *const WindowHandle) !os.WindowSize {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == w32.FALSE) {
            return error.FailedToGetClientRect;
        }
        return os.WindowSize{.width = rect.right, .height = rect.bottom};
    }

    pub fn copy_string_to_clipboard(self: *const WindowHandle, str: []const u8) !void {
        const handle = w32.GlobalAlloc(w32.GHND, str.len + 1) orelse {
            return error.FailedToAllocateClipboardData;
        };
        var we_own_handle = true;
        errdefer {
            if (we_own_handle) {
                _ = w32.GlobalFree(handle);
            }
        }

        {
            const ptr = w32.GlobalLock(handle) orelse {
                return error.FailedToLockClipboardData;
            };
            defer _ = w32.GlobalUnlock(handle);

            const str_ptr = @as([*]u8, @ptrCast(ptr));
            @memcpy(str_ptr[0..], str[0..]);
            str_ptr[str.len] = 0;
        }

        if (w32.OpenClipboard(self.hwnd) == w32.FALSE) {
            return error.FailedToOpenClipboard;
        }
        defer _ = w32.CloseClipboard();

        if (w32.EmptyClipboard() == w32.FALSE) {
            return error.FailedToEmptyClipboard;
        }

        if (w32.SetClipboardData(w32.CF_TEXT, handle) == null) {
            return error.FailedToSetClipboardData;
        }
        we_own_handle = false;
    }

    pub fn get_string_from_clipboard(self: *const WindowHandle, alloc: std.mem.Allocator) ![]u8 {
        if (w32.OpenClipboard(self.hwnd) == w32.FALSE) {
            return error.FailedToOpenClipboard;
        }
        defer _ = w32.CloseClipboard();

        if (w32.IsClipboardFormatAvailable(w32.CF_TEXT) == w32.FALSE) {
            return error.ClipboardDoesNotContainText;
        }

        const handle = w32.GetClipboardData(w32.CF_TEXT) orelse {
            return error.FailedToGetClipboardData;
        };

        const size = w32.GlobalSize(handle);
        if (size == 0) {
            return error.ClipboardIsEmpty;
        }
        if (size > (1024 * 1024)) {
            return error.ClipboardIsTooBig;
        }

        const str = alloc.alloc(u8, size - 1) catch {
            return error.FailedToAllocateMemoryForClipboardData;
        };
        errdefer alloc.free(str);

        const ptr = w32.GlobalLock(handle) orelse {
            return error.FailedToLockClipboardData;
        };
        defer _ = w32.GlobalUnlock(handle);

        const ptr_slice = @as([*]const u8, @ptrCast(ptr))[0..(size - 1)];

        @memcpy(str[0..], ptr_slice[0..]);

        return str;
    }

    pub fn open_directory_in_file_explorer(self: *WindowHandle, path: [:0]const u8) !void {
        const return_value = w32.ShellExecuteA(self.hwnd, null, path.ptr, null, null, w32.SW_SHOWNORMAL);
        const return_value_int = @intFromPtr(return_value);
        if (return_value_int < 32) {
            std.log.err("ShellExecute failed with code: {}", .{return_value_int});
            return error.Failed;
        }
    }
};

fn construct_key_event(w_param: w32.WPARAM, l_param: w32.LPARAM) ?os.KeyEvent {
    const key = convert_windows_keycode(w_param);
    if (key == null) { return null; }

    return os.KeyEvent {
        .keycode = key.?,
        .scan_code = @intCast((l_param >> 16) & 0xff),
        .repeat_count = @intCast(l_param & 0xffff),
    };
}

fn construct_char_event(w_param: w32.WPARAM, l_param: w32.LPARAM) os.CharEvent {
    const utf8_seq = [2:0]u8{@intCast(w_param), @intCast(w_param >> 8)};
    return os.CharEvent {
        .utf8_char_seq = utf8_seq,
        .utf8_char_len = if (utf8_seq[1] == 0) 1 else 2,
        .scan_code = @intCast((l_param >> 16) & 0xff),
        .repeat_count = @intCast(l_param & 0xffff),
    };
}

fn construct_cursor_move_event(w_param: w32.WPARAM, l_param: w32.LPARAM) os.CursorMoveEvent {
    _ = w_param;
    return os.CursorMoveEvent {
        .x_coord = @intCast(GET_X_LPARAM(l_param)),
        .y_coord = @intCast(GET_Y_LPARAM(l_param)),
    };
}

fn GET_X_LPARAM(l_param: w32.LPARAM) c_int {
    return @intCast(LOWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param))))));
}

fn GET_Y_LPARAM(l_param: w32.LPARAM) c_int {
    return @intCast(HIWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param))))));
}

fn LOWORD(dword: w32.DWORD) w32.WORD {
    return @truncate(dword & @as(w32.DWORD, 0xffff));
}
fn HIWORD(dword: w32.DWORD) w32.WORD {
    return @truncate((dword >> 16) & @as(w32.DWORD, 0xffff));
}

export fn window_proc(hwnd: w32.HWND, u_msg: w32.UINT, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    switch (u_msg) {
        w32.WM_CLOSE => {
            if (eng.get().os.find_hwnd_id(hwnd)) |id| {
                push_window_event_to_queue(os.WindowEvent { .WINDOW_REQUESTED_CLOSE = @intCast(id), });
                return 0;
            } else {
                std.log.err("WM_CLOSE recieved for an unknown hwnd", .{});
            }
        },
        w32.WM_DESTROY => {
            if (eng.get().os.find_hwnd_id(hwnd)) |id| {
                eng.get().os.window_thread_hwnd_map[id] = null;
                push_window_event_to_queue(os.WindowEvent { .WINDOW_CLOSED = @intCast(id) });
            } else {
                std.log.err("WM_DESTROY recieved for an unknown hwnd", .{});
            }
        },

        w32.WM_SIZE => {
            push_window_event_to_queue(os.WindowEvent { .RESIZED = os.WindowSize {
                .width = @intCast(LOWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param)))))),
                .height = @intCast(HIWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param)))))),
            } });
        },
        w32.WM_SETFOCUS => {
            push_window_event_to_queue(os.WindowEvent { .GAINED_FOCUS = undefined });
        },
        w32.WM_KILLFOCUS => {
            push_window_event_to_queue(os.WindowEvent { .LOST_FOCUS = undefined });
        },

        w32.WM_KEYDOWN => { 
            const keyevent = construct_key_event(w_param, l_param);
            if (keyevent == null) { return 0; }

            // Check if the previous key state bit is set
            if ((l_param & (1 << 30)) != 0) {
                push_window_event_to_queue(os.WindowEvent { .KEY_REPEAT = keyevent.? });
            } else {
                push_window_event_to_queue(os.WindowEvent { .KEY_DOWN = keyevent.? });
            }
        },
        w32.WM_KEYUP => { 
            const keyevent = construct_key_event(w_param, l_param);
            if (keyevent == null) { return 0; }

            push_window_event_to_queue(os.WindowEvent { .KEY_UP = keyevent.? }); 
        },
        w32.WM_CHAR => {
            push_window_event_to_queue(os.WindowEvent { .CHAR = construct_char_event(w_param, l_param) });
        },

        w32.WM_MOUSEMOVE => {
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
        },
        w32.WM_LBUTTONDOWN => {
            _ = w32.SetCapture(hwnd);
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_DOWN = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseLeft,
                .repeat_count = 1,
                .scan_code = 0,
            }});
        },
        w32.WM_LBUTTONUP => {
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_UP = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseLeft,
                .repeat_count = 1,
                .scan_code = 0,
            }});
            _ = w32.ReleaseCapture();
        },
        w32.WM_MBUTTONDOWN => {
            _ = w32.SetCapture(hwnd);
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_DOWN = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseMiddle,
                .repeat_count = 1,
                .scan_code = 0,
            }});
        },
        w32.WM_MBUTTONUP => {
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_UP = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseMiddle,
                .repeat_count = 1,
                .scan_code = 0,
            }});
            _ = w32.ReleaseCapture();
        },
        w32.WM_RBUTTONDOWN => {
            _ = w32.SetCapture(hwnd);
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_DOWN = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseRight,
                .repeat_count = 1,
                .scan_code = 0,
            }});
        },
        w32.WM_RBUTTONUP => {
            push_window_event_to_queue(os.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
            push_window_event_to_queue(os.WindowEvent { .KEY_UP = os.KeyEvent {
                .keycode = eng.input.KeyCode.MouseRight,
                .repeat_count = 1,
                .scan_code = 0,
            }});
            _ = w32.ReleaseCapture();
        },

        w32.WM_INPUT => {
            const mouse_data = get_mouse_raw_data(l_param);
            if (mouse_data != null) {
                push_window_event_to_queue(os.WindowEvent { .RAW_MOUSE_MOVED = os.RawMouseMoveEvent {
                    .x_delta = mouse_data.?.lLastX,
                    .y_delta = mouse_data.?.lLastY,
                }});
            }
        },

        w32.WM_DROPFILES => (blk: {
            defer w32.DragFinish(w_param);
            
            const alloc = eng.get().general_allocator;

            const file_count = w32.DragQueryFileA(w_param, 0xFFFFFFFF, 0, 0);

            const file_paths = alloc.alloc([]u8, file_count) catch |err| break :blk err;
            errdefer alloc.free(file_paths);

            var file_paths_list = std.ArrayList([]u8).initBuffer(file_paths);
            errdefer for (file_paths_list.items) |path| { alloc.free(path); };

            for (0..file_count) |file_index| {
                const required_file_buffer_size = w32.DragQueryFileA(w_param, @truncate(file_index), null, 0);

                const file_path_buffer_0: [:0]u8 = alloc.allocSentinel(u8, required_file_buffer_size, 0) catch |err| break :blk err;
                defer alloc.free(file_path_buffer_0);

                const result = w32.DragQueryFileA(w_param, @truncate(file_index), file_path_buffer_0.ptr, @truncate(file_path_buffer_0.len + 1));
                if (result == 0) {
                    break :blk error.UnableToGetFilePath;
                }

                const file_path_buffer = alloc.dupe(u8, file_path_buffer_0) catch |err| break :blk err;
                errdefer alloc.free(file_path_buffer);

                // std.mem.replaceScalar(u8, file_path_buffer, '\\', '/');

                file_paths_list.appendBounded(file_path_buffer) catch |err| break :blk err;
            }

            push_window_event_to_queue(os.WindowEvent { .DROPPED_FILES = .{
                .paths = file_paths,
            }, });
        }) catch |err| {
            std.log.err("Error receiving dropped file: {}", .{err});
        },

        else => {},
    }
    return w32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
}


// Raw Input Windows API //

const RAWINPUTDEVICE = extern struct {
    usUsagePage: w32.USHORT,
    usUsage: w32.USHORT,
    dwFlags: w32.DWORD,
    hwndTarget: w32.HWND,
};

const PCRAWINPUTDEVICE = ?[*]const *RAWINPUTDEVICE;

extern "user32" fn RegisterRawInputDevices(pRawInputDevices: PCRAWINPUTDEVICE, uiNumDevices: w32.UINT, cbSize: w32.UINT) callconv(.winapi) w32.BOOL;

fn register_mouse_for_raw_input(hwnd: w32.HWND) bool {
    const raw_input_devices = [_]RAWINPUTDEVICE {
        RAWINPUTDEVICE {
            .hwndTarget = hwnd,
            .usUsagePage = 0x01, // Generic Desktop Controls Usage Page
            .usUsage = 0x02, // Mouse ID within the above page
            .dwFlags = 0x00, // Dont apply any flags
        },
    };
    return RegisterRawInputDevices(@ptrCast(&raw_input_devices), raw_input_devices.len, @sizeOf(RAWINPUTDEVICE)) == w32.TRUE;
}

const RAWINPUTHEADER = extern struct {
    dwType: w32.DWORD,
    dwSize: w32.DWORD,
    hDevice: w32.HANDLE,
    wParam: w32.WPARAM,
};

const RAWMOUSE = extern struct {
    usFlags: w32.USHORT,
    dummy: extern union {
        ulButtons: w32.ULONG,
        dummy: extern struct {
            usButtonFlags: w32.USHORT,
            usButtonData: w32.USHORT,
        },
    },
    ulRawButtons: w32.ULONG,
    lLastX: w32.LONG,
    lLastY: w32.LONG,
    ulExtraInformation: w32.ULONG,
};

const RAWKEYBOARD = extern struct {
    MakeCode: w32.USHORT,
    Flags: w32.USHORT,
    Reserved: w32.USHORT,
    VKey: w32.USHORT,
    Message: w32.UINT,
    ExtraInformation: w32.ULONG,
};

const RAWHID = extern struct {
    dwSizeHid: w32.DWORD,
    dwCount: w32.DWORD,
    bRawData: [1]w32.BYTE,
};

const RAWINPUT = extern struct {
    header: RAWINPUTHEADER,
    data: extern union {
        mouse: RAWMOUSE,
        keyboard: RAWKEYBOARD,
        hid: RAWHID,
    },
};

extern "user32" fn GetRawInputData(hRawInput: w32.LPARAM, uiCommand: w32.UINT, pData: w32.LPVOID, pcbSize: ?*w32.UINT, cbSizeHeader: w32.UINT) callconv(.winapi) w32.UINT;

fn get_mouse_raw_data(l_param: w32.LPARAM) ?RAWMOUSE {
    var raw_input: RAWINPUT = undefined;
    var pcbSize: w32.UINT = @sizeOf(RAWINPUT);
    const bytesCopied = GetRawInputData(l_param, 0x10000003, @ptrCast(&raw_input), &pcbSize, @sizeOf(RAWINPUTHEADER));
    if (bytesCopied == 0 or bytesCopied > @sizeOf(RAWINPUT)) {
        std.log.err("Windows getting raw input failed... value is: {}", .{bytesCopied});
        return null;
    }
    return raw_input.data.mouse;
}

const std = @import("std");
const eng = @import("self");
const wb = eng.window;
const w32 = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("combaseapi.h");
    @cInclude("shellapi.h");
});

const __c = @import("windows_keycode.zig");
const convert_windows_keycode = __c.convert_windows_keycode;


const GlobalEnginePtr = struct {
    engine: ?*anyopaque,
    window_event_callback: *const fn (*anyopaque, wb.WindowEvent) void,

    pub fn send_window_event(self: *@This(), event: wb.WindowEvent) void {
        if (self.engine != null) {
            self.window_event_callback(self.engine.?, event);
        } else {
            std.log.warn("window callback received when no engine defined!?!?!?!", .{});
        }
    }
};

var g_engine: GlobalEnginePtr = GlobalEnginePtr {
    .engine = null,
    .window_event_callback = undefined,
};

pub const Win32Window = struct {
    hInstance: w32.HINSTANCE,
    wc: w32.WNDCLASSEXA,
    hwnd: w32.HWND,

    pub fn init() !Win32Window {
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

        var wc = w32.WNDCLASSEXA{
            .lpfnWndProc = Win32Window.window_proc,
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
            return error.UnableToRegisterClass;
        }

        // width and height is what we want client rect to be 
        // CreateWindowExA takes in absolute height and width including title bar and border
        // Convert using AdjustWindowRectEx then pass rect into CreateWindowExA
        const width = 1920;
        const height = 1080;

        var rect = w32.RECT {
            .left = 0,
            .right = width,
            .top = 0,
            .bottom = height,
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
            "Window Made using Zig",
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

        if (!register_mouse_for_raw_input(hwnd)) {
            std.log.warn("Failed to get raw mouse input..", .{});
        }

        w32.DragAcceptFiles(hwnd, w32.TRUE);

        return Win32Window {
            .hInstance = hInstance,
            .wc = wc,
            .hwnd = hwnd,
        };
    }

    pub fn deinit(self: *Win32Window) void {
        _ = self;
        g_engine.engine = null;
        w32.CoUninitialize();
    }

    pub fn run(self: *Win32Window, engine: *anyopaque, window_event_callback: *const fn(*anyopaque, wb.WindowEvent) void) void {
        _ = self;
        if (g_engine.engine != null) { 
            std.log.warn("Only one Windows window is currently supported.", .{});
            return;
        }

        g_engine.window_event_callback = window_event_callback;
        g_engine.engine = engine;
        defer g_engine.engine = null;

        var msg = std.mem.zeroes(w32.MSG);
        main_loop: while (msg.message != w32.WM_QUIT) {
            while (w32.PeekMessageA(&msg, null, 0, 0, w32.PM_REMOVE) == w32.TRUE) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageA(&msg);

                if (msg.message == w32.WM_QUIT) {
                    break :main_loop;
                }
            }

            // update
            g_engine.send_window_event(wb.WindowEvent {.EVENTS_CLEARED = undefined});
        }
    }

    pub fn get_platform_window(self: *Win32Window) w32.HWND {
        return self.hwnd;
    }

    pub fn get_client_size(self: *const Win32Window) !wb.WindowSize {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == w32.FALSE) {
            return error.FailedToGetClientRect;
        }
        return wb.WindowSize{.width = rect.right, .height = rect.bottom};
    }

    pub fn show_cursor(self: *Win32Window, should_show_cursor: bool) void {
        _ = self;
        // Windows shows the cursor if an internal counter is greater than or
        // equal to 0 and hides it if it is less than 0. The value of this counter
        // is returned each ShowCursor(). To make sure this function behaves properly
        // we need to manage this internal counter with while loops.
        if (should_show_cursor) {
            while (w32.ShowCursor(1) < 0) {}
        } else {
            while (w32.ShowCursor(0) >= 0) {}
        }
    }

    pub fn free_confined_cursor(self: *Win32Window) void {
        _ = self;
        _ = w32.ClipCursor(null);
    }

    pub fn confine_cursor(self: *Win32Window, rect: wb.Rect) void {
        _ = self;
        const w32rect = w32.RECT {
            .left = rect.x,
            .right = rect.x + rect.width,
            .top = rect.y,
            .bottom = rect.y + rect.height,
        };
        _ = w32.ClipCursor(&w32rect);
    }

    pub fn copy_string_to_clipboard(self: *const Win32Window, str: []const u8) !void {
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

    pub fn get_string_from_clipboard(self: *const Win32Window, alloc: std.mem.Allocator) ![]u8 {
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

    pub fn confine_cursor_to_current_pos(self: *Win32Window) void {
        var cursor_pos: w32.POINT = undefined;
        if (w32.GetCursorPos(&cursor_pos) == 0) { return; }
        self.confine_cursor(wb.Rect{
            .x = cursor_pos.x,
            .y = cursor_pos.y,
            .width = 1,
            .height = 1,
        });
    }

    fn construct_key_event(w_param: w32.WPARAM, l_param: w32.LPARAM) ?wb.KeyEvent {
        const key = convert_windows_keycode(w_param);
        if (key == null) { return null; }

        return wb.KeyEvent {
            .keycode = key.?,
            .scan_code = @intCast((l_param >> 16) & 0xff),
            .repeat_count = @intCast(l_param & 0xffff),
        };
    }

    fn construct_char_event(w_param: w32.WPARAM, l_param: w32.LPARAM) wb.CharEvent {
        const utf8_seq = [2:0]u8{@intCast(w_param), @intCast(w_param >> 8)};
        return wb.CharEvent {
            .utf8_char_seq = utf8_seq,
            .utf8_char_len = if (utf8_seq[1] == 0) 1 else 2,
            .scan_code = @intCast((l_param >> 16) & 0xff),
            .repeat_count = @intCast(l_param & 0xffff),
        };
    }

    fn construct_cursor_move_event(w_param: w32.WPARAM, l_param: w32.LPARAM) wb.CursorMoveEvent {
        _ = w_param;
        return wb.CursorMoveEvent {
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
            w32.WM_DESTROY => {
                w32.PostQuitMessage(0);
                return 0;
            },
            w32.WM_SIZE => { 
                g_engine.send_window_event(wb.WindowEvent { .RESIZED = wb.WindowSize {
                    .width = @intCast(LOWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param)))))),
                    .height = @intCast(HIWORD(@as(w32.DWORD, @truncate(@as(c_ulonglong, @bitCast(l_param)))))),
                } });
                return 0;
            },
            w32.WM_SETFOCUS => {
                g_engine.send_window_event(wb.WindowEvent { .GAINED_FOCUS = undefined });
                return 0;
            },
            w32.WM_KILLFOCUS => {
                g_engine.send_window_event(wb.WindowEvent { .LOST_FOCUS = undefined });
                return 0;
            },

            w32.WM_KEYDOWN => { 
                const keyevent = construct_key_event(w_param, l_param);
                if (keyevent == null) { return 0; }

                // Check if the previous key state bit is set
                if ((l_param & (1 << 30)) != 0) {
                    g_engine.send_window_event(wb.WindowEvent { .KEY_REPEAT = keyevent.? });
                } else {
                    g_engine.send_window_event(wb.WindowEvent { .KEY_DOWN = keyevent.? });
                }
                return 0;
            },
            w32.WM_KEYUP => { 
                const keyevent = construct_key_event(w_param, l_param);
                if (keyevent == null) { return 0; }

                g_engine.send_window_event(wb.WindowEvent { .KEY_UP = keyevent.? }); 
                return 0;
            },
            w32.WM_CHAR => {
                g_engine.send_window_event(wb.WindowEvent { .CHAR = construct_char_event(w_param, l_param) });
                return 0;
            },

            w32.WM_MOUSEMOVE => {
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                return 0;
            },
            w32.WM_LBUTTONDOWN => {
                _ = w32.SetCapture(hwnd);
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_DOWN = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseLeft,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                return 0;
            },
            w32.WM_LBUTTONUP => {
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_UP = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseLeft,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                _ = w32.ReleaseCapture();
                return 0;
            },
            w32.WM_MBUTTONDOWN => {
                _ = w32.SetCapture(hwnd);
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_DOWN = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseMiddle,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                return 0;
            },
            w32.WM_MBUTTONUP => {
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_UP = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseMiddle,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                _ = w32.ReleaseCapture();
                return 0;
            },
            w32.WM_RBUTTONDOWN => {
                _ = w32.SetCapture(hwnd);
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_DOWN = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseRight,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                return 0;
            },
            w32.WM_RBUTTONUP => {
                g_engine.send_window_event(wb.WindowEvent { .CURSOR_MOVED = construct_cursor_move_event(w_param, l_param) });
                g_engine.send_window_event(wb.WindowEvent { .KEY_UP = wb.KeyEvent {
                    .keycode = eng.input.KeyCode.MouseRight,
                    .repeat_count = 1,
                    .scan_code = 0,
                }});
                _ = w32.ReleaseCapture();
                return 0;
            },

            w32.WM_INPUT => {
                const mouse_data = get_mouse_raw_data(l_param);
                if (mouse_data != null) {
                    g_engine.send_window_event(wb.WindowEvent { .RAW_MOUSE_MOVED = wb.RawMouseMoveEvent {
                        .x_delta = mouse_data.?.lLastX,
                        .y_delta = mouse_data.?.lLastY,
                    }});
                }
                return 0;
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

                g_engine.send_window_event(wb.WindowEvent { .DROPPED_FILES = .{
                    .paths = file_paths,
                }, });
            }) catch |err| {
                std.log.err("Error receiving dropped file: {}", .{err});
            },

            else => {},
        }
        return w32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
    }
};


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

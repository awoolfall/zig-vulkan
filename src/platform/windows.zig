const std = @import("std");
const zwin32 = @import("zwin32");
const w32 = zwin32.w32;

const __c = @import("windows_keycode.zig");
const convert_windows_keycode = __c.convert_windows_keycode;
const __k = @import("../input/keycode.zig");
const wb = @import("../window.zig");


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

        var hInstance: w32.HINSTANCE = @ptrCast(w32.GetModuleHandleA(null));
        var wc = w32.WNDCLASSEXA{
            .lpfnWndProc = Win32Window.window_proc,
            .hInstance = hInstance,
            .lpszClassName = "Window Class",
            .style = 0,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .hIconSm = null,
        };
        _ = w32.RegisterClassExA(&wc);
        var hwnd = w32.CreateWindowExA(
            0, 
            "Window Class", 
            "Window Made using Zig",
            w32.WS_OVERLAPPEDWINDOW + w32.WS_VISIBLE,
            w32.CW_USEDEFAULT,
            w32.CW_USEDEFAULT, 
            1920, 1080, 
            null, null,
            hInstance, 
            null).?;

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

    pub fn get_client_size(self: *Win32Window) !wb.WindowSize {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == w32.FALSE) {
            return error.FailedToGetClientRect;
        }
        return wb.WindowSize{.width = rect.right, .height = rect.bottom};
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
        var ce = wb.CharEvent {
            .utf8_char_seq = utf8_seq,
            .utf8_char_len = if (utf8_seq[1] == 0) 1 else 2,
            .scan_code = @intCast((l_param >> 16) & 0xff),
            .repeat_count = @intCast(l_param & 0xffff),
        };
        return ce;
    }

    export fn window_proc(hwnd: w32.HWND, u_msg: w32.UINT, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(w32.WINAPI) w32.LRESULT {
        switch (u_msg) {
            w32.WM_DESTROY => {
                w32.PostQuitMessage(0);
                return 0;
            },
            w32.WM_SIZE => { 
                g_engine.send_window_event(wb.WindowEvent { .RESIZED = wb.WindowSize {
                    .width = @intCast(w32.LOWORD(@intCast(l_param))),
                    .height = @intCast(w32.HIWORD(@intCast(l_param))),
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

            else => {},
        }
        return w32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
    }
};


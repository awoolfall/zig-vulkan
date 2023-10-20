const std = @import("std");
const zwin32 = @import("zwin32");
const w32 = zwin32.w32;

const __c = @import("windows_keycode.zig");
const convert_windows_keycode = __c.convert_windows_keycode;
const __k = @import("../input/keycode.zig");
const wb = @import("../window.zig");


pub const Vec2 = struct {
    x: f32,
    y: f32,
};

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

    pub fn init(engine: *anyopaque, window_event_callback: *const fn(*anyopaque, wb.WindowEvent) void) !Win32Window {
        if (g_engine.engine == null) {
            g_engine.window_event_callback = window_event_callback;
            g_engine.engine = engine;
        }

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
            .hwnd = hwnd
        };
    }

    pub fn deinit(self: *Win32Window) void {
        _ = self;
        g_engine.engine = null;
        w32.CoUninitialize();
    }

    pub fn run(self: *Win32Window) void {
        _ = self;
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

    pub fn get_client_size(self: *Win32Window) !Vec2 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == w32.FALSE) {
            return error.FailedToGetClientRect;
        }
        return Vec2 { .x = @floatFromInt(rect.right), .y = @floatFromInt(rect.bottom) };
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
        return wb.CharEvent {
            .utf32_char_code = @intCast(w_param),
            .scan_code = @intCast((l_param >> 16) & 0xff),
            .repeat_count = @intCast(l_param & 0xffff),
        };
    }

    export fn window_proc(hwnd: w32.HWND, u_msg: w32.UINT, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(w32.WINAPI) w32.LRESULT {
        switch (u_msg) {
            w32.WM_DESTROY => {
                w32.PostQuitMessage(0);
                return 0;
            },
            w32.WM_SIZE => { 
                g_engine.send_window_event(wb.WindowEvent { .RESIZED = undefined });
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
                // Handle UNICODE_NOCHAR case
                if (w_param == 65535) { return w32.TRUE; }

                g_engine.send_window_event(wb.WindowEvent { .CHAR = construct_char_event(w_param, l_param) });
                return 0;
            },
            else => {},
        }
        return w32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
    }
};


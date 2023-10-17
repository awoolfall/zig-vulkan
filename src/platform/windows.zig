const std = @import("std");
const zwin32 = @import("zwin32");
const w32 = zwin32.w32;

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

const GlobalEnginePtr = struct {
    engine: ?*align(8) anyopaque,
    window_event_callback: *const fn (*align(8) anyopaque, WindowEvent) void,

    pub fn send_window_event(self: *@This(), event: WindowEvent) void {
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

    pub fn init(engine: *align(8) anyopaque, window_event_callback: *const fn(*align(8) anyopaque, WindowEvent) void) !Win32Window {
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
            g_engine.send_window_event(WindowEvent {.EVENTS_CLEARED = undefined});
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

    export fn window_proc(hwnd: w32.HWND, u_msg: w32.UINT, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(w32.WINAPI) w32.LRESULT {
        switch (u_msg) {
            w32.WM_DESTROY => {
                w32.PostQuitMessage(0);
                return 0;
            },
            w32.WM_SIZE => { g_engine.send_window_event(WindowEvent { .RESIZED = undefined }); },
            else => {
                return w32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
            },
        }
        return 0;
    }
};

pub const WindowEventTag = enum {
    RESIZED,
    EVENTS_CLEARED,
};

pub const WindowEvent = union(WindowEventTag) {
    RESIZED: void,
    EVENTS_CLEARED: void,
};

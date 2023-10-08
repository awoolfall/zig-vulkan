const std = @import("std");
const windows = std.os.windows;

const engine = @import("engine.zig");

export fn window_proc(hwnd: windows.HWND, u_msg: windows.UINT, w_param: windows.WPARAM, l_param: windows.LPARAM) windows.LRESULT {
    switch (u_msg) {
        windows.user32.WM_DESTROY => {
            windows.user32.PostQuitMessage(0);
            return 0;
        },
        else => {
            return windows.user32.DefWindowProcA(hwnd, u_msg, w_param, l_param);
        },
    }
}

pub const Window = struct {
    hInstance: windows.HINSTANCE,
    wc: windows.user32.WNDCLASSEXA,
    hwnd: windows.HWND,

    pub fn create() !Window {
        var hInstance: windows.HINSTANCE = @ptrCast(windows.kernel32.GetModuleHandleW(null));
        var wc = windows.user32.WNDCLASSEXA{
            .lpfnWndProc = window_proc,
            .hInstance = hInstance,
            .lpszClassName = "Window Class",
            .style = 0,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .hIconSm = null,
        };
        _ = windows.user32.RegisterClassExA(&wc);
        var hwnd = windows.user32.CreateWindowExA(
            0, 
            "Window Class", 
            "Window Made using Zig",
            windows.user32.WS_OVERLAPPEDWINDOW,
            windows.user32.CW_USEDEFAULT,
            windows.user32.CW_USEDEFAULT, 
            1920, 1080, 
            null, null,
            hInstance, 
            null).?;
        _ = windows.user32.ShowWindow(hwnd, windows.user32.SW_SHOW);

        return Window {
            .hInstance = hInstance,
            .wc = wc,
            .hwnd = hwnd,
        };
    }
};

pub fn main() !void {
    std.debug.print("Hello from zig!!\n", .{});

    var window = try Window.create();
    _ = window;

    var e = try engine.Engine.init();

    var msg = std.mem.zeroes(windows.user32.MSG);
    while (msg.message != windows.user32.WM_QUIT) {
        while (windows.user32.PeekMessageA(&msg, null, 0, 0, windows.user32.PM_REMOVE) >= 1) {
            _ = windows.user32.TranslateMessage(&msg);
            _ = windows.user32.DispatchMessageA(&msg);
        }

        // update
        try e.update();
    }
}

// pub fn main() !void {
//     // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
//     std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
//
//     // stdout is for the actual output of your application, for example if you
//     // are implementing gzip, then only the compressed bytes should be sent to
//     // stdout, not any debugging messages.
//     const stdout_file = std.io.getStdOut().writer();
//     var bw = std.io.bufferedWriter(stdout_file);
//     const stdout = bw.writer();
//
//     try stdout.print("Run `zig build test` to run the tests.\n", .{});
//
//     try bw.flush(); // don't forget to flush!
// }
//
// test "simple test" {
//     var list = std.ArrayList(i32).init(std.testing.allocator);
//     defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
//     try list.append(42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

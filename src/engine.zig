const std = @import("std");
const zwin32 = @import("zwin32");
const hrPanic = zwin32.hrPanicOnFail;

const d3d11 = @import("gfx/d3d11.zig");
const w32 = @import("platform/windows.zig");

pub fn Engine(comptime App: type) type {
    return struct {
        const Self = @This();
        const Log = std.log.scoped(.Engine);

        window: w32.Win32Window,
        gfx: d3d11.D3D11State,
        app: App,

        pub fn run() !void {
            Log.debug("Engine init!", .{});

            var engine = Self {
                .window = undefined,
                .gfx = undefined,
                .app = undefined,
            };

            Log.debug("Calling Window init!", .{});
            engine.window = try w32.Win32Window.init(@ptrCast(&engine), &Self.window_event_received);
            defer engine.window.deinit();

            Log.debug("Calling GFX init!", .{});
            engine.gfx = try d3d11.D3D11State.init(&engine.window);
            defer engine.gfx.deinit();

            Log.debug("Calling app init!", .{});
            engine.app = try App.init(&engine);
            defer engine.app.deinit();

            Log.debug("Engine inited!", .{});
            engine.window.run();
        }

        fn window_event_received(engine_void_ptr: *align(8) anyopaque, event: w32.WindowEvent) void {
            const self: *Self = @ptrCast(engine_void_ptr);

            switch (event) {
                .RESIZED => { self.gfx.window_resized(); },
                else => {},
            }
            self.app.window_event_received(event);
        }
    };
}


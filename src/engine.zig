const std = @import("std");
const zwin32 = @import("zwin32");
const hrPanic = zwin32.hrPanicOnFail;

const d3d11 = @import("gfx/d3d11.zig");
const w32 = @import("platform/windows.zig");

const wb = @import("window.zig");

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
            engine.window = try w32.Win32Window.init();
            defer engine.window.deinit();

            Log.debug("Calling GFX init!", .{});
            engine.gfx = try d3d11.D3D11State.init(&engine.window);
            defer engine.gfx.deinit();

            Log.debug("Calling app init!", .{});
            engine.app = try App.init(&engine);
            defer engine.app.deinit();

            Log.debug("Engine inited!", .{});
            engine.window.run(@ptrCast(&engine), &Self.window_event_received);
        }

        fn window_event_received(engine_void_ptr: *anyopaque, event: wb.WindowEvent) void {
            const self: *Self = @ptrCast(@alignCast(engine_void_ptr));

            switch (event) {
                .RESIZED => |new_size| { self.gfx.window_resized(new_size.width, new_size.height); },
                else => {},
            }
            self.app.window_event_received(event);
        }
    };
}


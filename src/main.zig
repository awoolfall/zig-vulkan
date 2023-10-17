const std = @import("std");
const zwin32 = @import("zwin32");
const w32 = zwin32.w32;
const d3d12 = zwin32.d3d12;

const engine = @import("engine.zig");
const window = @import("platform/windows.zig");

const App = struct {
    const Self = @This();

    engine: *engine.Engine(Self),
    a: i32,
    b: i32,
    c: i32,

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});

        return Self {
            .engine = eng,
            .a = undefined,
            .b = undefined,
            .c = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        std.log.info("App deinit!", .{});
    }

    fn update(self: *Self) void {
        _ = self;
        return;
    }

    pub fn window_event_received(self: *Self, event: window.WindowEvent) void {
        switch (event) {
            .EVENTS_CLEARED => { self.update(); },
            else => {},
        }
    }
};

pub fn main() !void {
    std.debug.print("Hello from zig!!\n", .{});

    var e = try engine.Engine(App).init();
    defer e.deinit();

    try e.run();
}


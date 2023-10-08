const std = @import("std");

pub const Engine = struct {
    pub fn init() !Engine {
        std.debug.print("engine init!\n", .{});
        return Engine{};
    }

    pub fn update(self: *Engine) !void {
        _ = self;
        //std.debug.print("engine update!\n", .{});
    }
};

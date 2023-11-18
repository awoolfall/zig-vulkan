const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    std.debug.print("Hello from zig!!\n", .{});
    try app.Engine.run();
}


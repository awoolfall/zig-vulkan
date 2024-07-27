const std = @import("std");
const builtin = @import("builtin");

pub const Window = switch (builtin.os.tag) {
    .windows => @import("windows.zig").Win32Window,
    else => @compileError("Unsupported OS!"),
};

pub const GfxPlatform = switch (builtin.os.tag) {
    .windows => @import("../gfx/platform/d3d11.zig").GfxStateD3D11,
    //.windows => @import("../gfx/platform/noop.zig").GfxStateNoop,
    else => @compileError("Unsupported OS!"),
};


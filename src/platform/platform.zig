const std = @import("std");
const builtin = @import("builtin");
pub const os = builtin.os;
pub const graphics_backend = @import("build_options").graphics_backend;

pub const Window = switch (builtin.os.tag) {
    .windows => @import("windows.zig").Win32Window,
    else => @compileError("Unsupported OS"),
};

pub const GfxPlatform = switch (graphics_backend) {
    .Direct3D11 => @import("../gfx/platform/d3d11.zig").GfxStateD3D11,
    .Vulkan => @import("../gfx/platform/vulkan.zig").GfxStateVulkan,
    .OpenGL_ES3 => @compileError("Not yet implemented"),
    .Noop => @import("../gfx/platform/noop.zig").GfxStateNoop,
};


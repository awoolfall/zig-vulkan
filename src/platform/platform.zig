const std = @import("std");
const builtin = @import("builtin");
pub const os = builtin.os;
pub const graphics_backend = @import("build_options").graphics_backend;

pub const Window = switch (builtin.os.tag) {
    .windows => @import("windows.zig").Win32Window,
    else => @compileError("Unsupported OS"),
};

pub const GfxPlatform = switch (graphics_backend) {
    .Vulkan => @import("../gfx/platform/vulkan.zig").GfxStateVulkan,
    .WebGPU => @compileError("Not yet implemented"),
    .Noop => @compileError("Not yet implemented"),
};


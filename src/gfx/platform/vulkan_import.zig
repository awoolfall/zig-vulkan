const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    switch (builtin.os.tag) {
        .windows => {
            @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
        },
        else => @compileError("Platform not implemented"),
    }
    @cInclude("vulkan/vulkan.h");
});


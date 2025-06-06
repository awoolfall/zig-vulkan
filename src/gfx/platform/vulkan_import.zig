const std = @import("std");
const builtin = @import("builtin");
const zwin = @import("zwindows");

pub const c = @cImport({
    switch (builtin.os.tag) {
        .windows => {
            @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
        },
        else => @compileError("Platform not implemented"),
    }
    @cInclude("vulkan/vulkan.h");
});

// Define a custom structure for win32 surface create info so that HINSTANCE and HWND can
// match the structures defined in zwindows. The generated HWND and HINSTANCE in 
// c.VkWin32SurfaceCreateInfoKHR does not have the correct alignment and causes
// crashes occasionally.
pub const VkWin32SurfaceCreateInfoKHR = if (builtin.os.tag == .windows)
    extern struct {
        sType: c.VkStructureType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
        pNext: ?*anyopaque = null,
        flags: c.VkWin32SurfaceCreateFlagsKHR = 0,
        hinstance: zwin.windows.HINSTANCE,
        hwnd: zwin.windows.HWND,

        // comptime function to make sure this function matches the 
        // signature found in the generated vulkan bindings
        comptime {
            const fields = @typeInfo(@This()).@"struct".fields;
            for (fields) |field| {
                std.debug.assert(@offsetOf(@This(), field.name) == @offsetOf(c.VkWin32SurfaceCreateInfoKHR, field.name));
            }
        }
    }
else void;

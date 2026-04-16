const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const ShaderModuleVulkan = struct {
    const Self = @This();

    vk_shader_module: c.VkShaderModule,

    pub fn deinit(self: *const Self) void {
        c.vkDestroyShaderModule(eng.get().gfx.platform.device, self.vk_shader_module, null);
    }

    pub fn init(info: gf.ShaderModuleInfo) !Self {
        const gfx = gf.GfxState.get();
        const alloc = gfx.platform.alloc;

        const aligned_data = try alloc.alignedAlloc(u8, std.mem.Alignment.@"4", info.spirv_data.len);
        defer alloc.free(aligned_data);
        @memcpy(aligned_data, info.spirv_data);

        const shader_create_info = c.VkShaderModuleCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = @intCast(aligned_data.len),
            .pCode = @ptrCast(aligned_data.ptr),// @ptrCast(@alignCast(shader_data.ptr)),
        };

        var shader_module: c.VkShaderModule = undefined;
        try vkt(c.vkCreateShaderModule(gfx.platform.device, &shader_create_info, null, &shader_module));
        errdefer c.vkDestroyShaderModule(gfx.platform.device, shader_module, null);

        return .{
            .vk_shader_module = shader_module,
        };
    }
};
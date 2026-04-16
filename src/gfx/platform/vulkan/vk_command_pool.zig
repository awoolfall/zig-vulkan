const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;
const CommandBufferVulkan = @import("vk_command_buffer.zig").CommandBufferVulkan;

pub const CommandPoolVulkan = struct {
    vk_pool: c.VkCommandPool,

    pub fn deinit(self: *const CommandPoolVulkan) void {
        c.vkDestroyCommandPool(GfxStateVulkan.get().device, self.vk_pool, null);
    }

    pub fn init(info: gf.CommandPoolInfo) !CommandPoolVulkan {
        //std.debug.assert(poolflags_to_vulkan(info) != 0);

        const pool_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.poolflags_to_vulkan(info),
            .queueFamilyIndex = GfxStateVulkan.get().get_queue_family_index(info.queue_family),
        };

        var vk_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(GfxStateVulkan.get().device, &pool_info, null, &vk_pool));
        errdefer c.vkDestroyCommandPool(GfxStateVulkan.get().device, vk_pool, null);

        return CommandPoolVulkan {
            .vk_pool = vk_pool,
        };
    }

    pub fn allocate_command_buffers(self: *CommandPoolVulkan, info: gf.CommandBufferInfo, comptime count: usize) ![count]CommandBufferVulkan {
        const alloc_info = c.VkCommandBufferAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandBufferCount = count,
            .commandPool = self.vk_pool,
            .level = vk.commandbufferlevel_to_vulkan(info.level),
        };

        var vk_command_buffers: [count]c.VkCommandBuffer = undefined;
        try vkt(c.vkAllocateCommandBuffers(GfxStateVulkan.get().device, &alloc_info, &vk_command_buffers));
        errdefer c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, count, &vk_command_buffers);

        var buffers: [count]CommandBufferVulkan = undefined;
        inline for (vk_command_buffers, 0..) |vk_b, idx| {
            buffers[idx] = CommandBufferVulkan {
                .vk_pool = self.vk_pool,
                .vk_command_buffer = vk_b,
            };
        }

        return buffers;
    }
};
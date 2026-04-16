const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const SemaphoreVulkan = struct {
    const Self = @This();

    vk_semaphore: c.VkSemaphore,

    pub inline fn deinit(self: *const Self) void {
        c.vkDestroySemaphore(GfxStateVulkan.get().device, self.vk_semaphore, null);
    }

    pub inline fn init(info: gf.SemaphoreCreateInfo) !Self {
        _ = info;

        const semaphore_info = c.VkSemaphoreCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        var vk_semaphore: c.VkSemaphore = undefined;
        try vkt(c.vkCreateSemaphore(GfxStateVulkan.get().device, &semaphore_info, null, &vk_semaphore));
        errdefer c.vkDestroySemaphore(GfxStateVulkan.get().device, vk_semaphore, null);

        return Self {
            .vk_semaphore = vk_semaphore,
        };
    }
};

pub const FenceVulkan = struct {
    const Self = @This();

    vk_fence: c.VkFence,

    pub inline fn deinit(self: *const Self) void {
        c.vkDestroyFence(GfxStateVulkan.get().device, self.vk_fence, null);
    }

    pub inline fn init(info: gf.FenceCreateInfo) !Self {
        const fence_info = c.VkFenceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = if (info.create_signalled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0,
        };

        var vk_fence: c.VkFence = undefined;
        try vkt(c.vkCreateFence(GfxStateVulkan.get().device, &fence_info, null, &vk_fence));
        errdefer c.vkDestroyFence(GfxStateVulkan.get().device, vk_fence, null);

        return Self {
            .vk_fence = vk_fence,
        };
    }

    pub inline fn wait(self: *Self) !void {
        vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                1,
                @ptrCast(&self.vk_fence),
                vk.bool_to_vulkan(true),
                std.math.maxInt(u64)
        )) catch |err| {
            std.log.warn("Failed waiting for fence: {}", .{err});
        };
    }

    pub inline fn wait_all(fences: []const *Self) !void {
        const MAX_FENCES = 16;
        std.debug.assert(fences.len < MAX_FENCES);

        var vk_fences: [MAX_FENCES]c.VkFence = undefined;
        for (fences, 0..) |f, idx| {
            vk_fences[idx] = f.vk_fence;
        }

        try vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                @intCast(fences.len),
                @ptrCast(vk_fences[0..].ptr),
                vk.bool_to_vulkan(true),
                std.math.maxInt(u64)
        ));
    }
    
    pub inline fn wait_any(fences: []const *Self) !void {
        const MAX_FENCES = 16;
        std.debug.assert(fences.len < MAX_FENCES);

        var vk_fences: [MAX_FENCES]c.VkFence = undefined;
        for (fences, 0..) |f, idx| {
            vk_fences[idx] = f.vk_fence;
        }

        try vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                @intCast(fences.len),
                @ptrCast(vk_fences[0..].ptr),
                vk.bool_to_vulkan(false),
                std.math.maxInt(u64)
        ));
    }

    pub inline fn reset(self: *Self) !void {
        try vkt(c.vkResetFences(GfxStateVulkan.get().device, 1, self.vk_fence));
    }
};

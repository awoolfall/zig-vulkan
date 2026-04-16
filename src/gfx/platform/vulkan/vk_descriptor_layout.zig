const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const DescriptorLayoutVulkan = struct {
    vk_layout: c.VkDescriptorSetLayout,
    
    pub fn deinit(self: *const DescriptorLayoutVulkan) void {
        c.vkDestroyDescriptorSetLayout(GfxStateVulkan.get().device, self.vk_layout, null);
    }

    pub fn init(info: gf.DescriptorLayoutInfo) !DescriptorLayoutVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        const vk_bindings = try alloc.alloc(c.VkDescriptorSetLayoutBinding, info.bindings.len);
        defer alloc.free(vk_bindings);

        for (info.bindings, 0..) |*binding, idx| {
            vk_bindings[idx] = c.VkDescriptorSetLayoutBinding {
                .binding = binding.binding,
                .descriptorType = vk.bindingtype_to_vulkan(binding.binding_type),
                .stageFlags = vk.shaderstageflags_to_vulkan(binding.shader_stages),
                .descriptorCount = binding.array_count,
                .pImmutableSamplers = null, // todo? idk
            };
        }

        const layout_info = c.VkDescriptorSetLayoutCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pBindings = @ptrCast(vk_bindings.ptr),
            .bindingCount = @intCast(vk_bindings.len),
        };

        var vk_layout: c.VkDescriptorSetLayout = undefined;
        try vkt(c.vkCreateDescriptorSetLayout(GfxStateVulkan.get().device, &layout_info, null, &vk_layout));
        errdefer c.vkDestroyDescriptorSetLayout(GfxStateVulkan.get().device, vk_layout, null);

        return DescriptorLayoutVulkan {
            .vk_layout = vk_layout,
        };
    }
};

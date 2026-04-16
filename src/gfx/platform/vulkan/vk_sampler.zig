const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const SamplerVulkan = struct {
    const Self = @This();

    vk_sampler: c.VkSampler,

    pub fn deinit(self: *const Self) void {
        c.vkDestroySampler(GfxStateVulkan.get().device, self.vk_sampler, null);
    }

    pub fn init(info: gf.SamplerInfo) !Self {
        const sampler_info = c.VkSamplerCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            
            .magFilter =  vk.samplerfilter_to_vulkan(info.filter_min_mag),
            .minFilter =  vk.samplerfilter_to_vulkan(info.filter_min_mag),

            .mipmapMode = vk.samplermipmapmode_to_vulkan(info.filter_mip),
            .mipLodBias = 0.0,

            .addressModeU = vk.samplerbordermode_to_vulkan(info.border_mode),
            .addressModeV = vk.samplerbordermode_to_vulkan(info.border_mode),
            .addressModeW = vk.samplerbordermode_to_vulkan(info.border_mode),

            .anisotropyEnable = vk.bool_to_vulkan(info.anisotropic_filter),
            .maxAnisotropy = 1, // TODO
            
            .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK, // todo?

            .minLod = info.min_lod,
            .maxLod = info.max_lod,

            .unnormalizedCoordinates = c.VK_FALSE,
            
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
        };

        var vk_sampler: c.VkSampler = undefined;
        try vkt(c.vkCreateSampler(GfxStateVulkan.get().device, &sampler_info, null, &vk_sampler));
        errdefer c.vkDestroySampler(GfxStateVulkan.get().device, vk_sampler, null);

        return Self {
            .vk_sampler = vk_sampler,
        };
    }
};
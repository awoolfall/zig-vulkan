const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const ImageViewVulkan = struct {
    const Self = @This();

    vk_image_views: []c.VkImageView,
    
    pub fn deinit(self: *const ImageViewVulkan) void {
        for (self.vk_image_views) |v| {
            c.vkDestroyImageView(GfxStateVulkan.get().device, v, null);
        }
        GfxStateVulkan.get().alloc.free(self.vk_image_views);
    }

    pub fn init(info: gf.ImageViewInfo) !ImageViewVulkan {
        const alloc = GfxStateVulkan.get().alloc;
        const img = try info.image.get();

        const view_type: c.VkImageViewType = switch (info.view_type) {
            .ImageView1D => c.VK_IMAGE_VIEW_TYPE_1D,
            .ImageView2D => c.VK_IMAGE_VIEW_TYPE_2D,
            .ImageView2DArray => c.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
            .ImageView3D => c.VK_IMAGE_VIEW_TYPE_3D,
        };

        const image_views = try alloc.alloc(c.VkImageView, img.platform.images.len);
        errdefer alloc.free(image_views);

        var image_views_list = std.ArrayList(c.VkImageView).initBuffer(image_views);
        errdefer for (image_views_list.items) |v| { c.vkDestroyImageView(GfxStateVulkan.get().device, v, null); };

        const aspect_mask = if (info.aspect_mask) |am| vk.imageaspect_to_vulkan(am) else unreachable;

        for (img.platform.images) |i| {
            const image_view_info = c.VkImageViewCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = i.vk_image, 
                .viewType = view_type,
                .format = img.platform.vk_format,
                .subresourceRange = .{
                    .aspectMask = aspect_mask,
                    .baseMipLevel = info.mip_levels.?.base_mip_level,
                    .levelCount = info.mip_levels.?.mip_level_count,
                    .baseArrayLayer = info.array_layers.?.base_array_layer,
                    .layerCount = info.array_layers.?.array_layer_count,
                },
            };

            var vk_image_view: c.VkImageView = undefined;
            try vkt(c.vkCreateImageView(GfxStateVulkan.get().device, &image_view_info, null, &vk_image_view));
            errdefer c.vkDestroyImageView(GfxStateVulkan.get().device, vk_image_view, null);

            try image_views_list.append(alloc, vk_image_view);
        }

        return ImageViewVulkan {
            .vk_image_views = image_views,
        };
    }

    pub inline fn get_frame_view(self: *const Self) c.VkImageView {
        if (self.vk_image_views.len == 1) { return self.vk_image_views[0]; }
        const idx = GfxStateVulkan.get().current_frame_index();
        std.debug.assert(idx < self.vk_image_views.len);
        return self.vk_image_views[idx];
    }
};
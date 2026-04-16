const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const SwapchainVulkan = struct {
    swapchain: c.VkSwapchainKHR,
    swapchain_images: []c.VkImage,
    swapchain_image_views: []c.VkImageView,

    surface_format: c.VkSurfaceFormatKHR,
    present_mode: c.VkPresentModeKHR,
    extent: c.VkExtent2D,

    current_image_index: u32 = 0,
    image_available_semaphores: []gf.Semaphore,
    present_transition_semaphores: []gf.Semaphore,

    pub fn deinit(self: *@This(), gfx_state: *GfxStateVulkan) void {
        for (self.swapchain_image_views) |image_view| {
            c.vkDestroyImageView(gfx_state.device, image_view, null);
        }
        gfx_state.alloc.free(self.swapchain_image_views);
        
        c.vkDestroySwapchainKHR(gfx_state.device, self.swapchain, null);
        gfx_state.alloc.free(self.swapchain_images);

        for (self.image_available_semaphores) |s| { s.deinit(); }
        gfx_state.alloc.free(self.image_available_semaphores);

        for (self.present_transition_semaphores) |s| { s.deinit(); }
        gfx_state.alloc.free(self.present_transition_semaphores);
    }

    pub const SwapchainCreateOptions = struct {
        width: u32,
        height: u32,
        format: c.VkSurfaceFormatKHR,
        present_mode: c.VkPresentModeKHR,
    };

    pub fn init(gfxstate: *GfxStateVulkan, opt: SwapchainCreateOptions) !SwapchainVulkan {
        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gfxstate.physical_device, gfxstate.surface, &surface_capabilities));

        var swapchain_extent = surface_capabilities.currentExtent;
        if (swapchain_extent.width == std.math.maxInt(u32)) {
            swapchain_extent = c.VkExtent2D {
                .width = std.math.clamp(@as(u32, @intCast(opt.width)),
                    surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
                .height = std.math.clamp(@as(u32, @intCast(opt.height)),
                    surface_capabilities.minImageExtent.height, surface_capabilities.maxImageExtent.height),
            };
        }
        if (swapchain_extent.width == 0 or swapchain_extent.height == 0) {
            return error.RequestedSwapchainSizeIsZero;
        }

        var swapchain_create_info = c.VkSwapchainCreateInfoKHR {
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = gfxstate.surface,
            .minImageCount = gfxstate.frames_in_flight(),
            .imageFormat = opt.format.format,
            .imageColorSpace = opt.format.colorSpace,
            .imageExtent = swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = surface_capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = opt.present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = @ptrCast(c.VK_NULL_HANDLE),
        };
        const swapchain_create_queue_indices = [2]u32 { gfxstate.queues.all_family_index, gfxstate.queues.present_family_index };
        if (gfxstate.queues.all_family_index == gfxstate.queues.present_family_index) {
            swapchain_create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swapchain_create_info.queueFamilyIndexCount = @intCast(swapchain_create_queue_indices.len);
            swapchain_create_info.pQueueFamilyIndices = &swapchain_create_queue_indices;
        }

        var vk_swapchain: c.VkSwapchainKHR = undefined;
        try vkt(c.vkCreateSwapchainKHR(gfxstate.device, &swapchain_create_info, null, &vk_swapchain));
        errdefer c.vkDestroySwapchainKHR(gfxstate.device, vk_swapchain, null);

        var swapchain_images_count: u32 = 0;
        try vkt(c.vkGetSwapchainImagesKHR(gfxstate.device, vk_swapchain, &swapchain_images_count, null));
        std.debug.assert(swapchain_images_count == gfxstate.frames_in_flight());

        const swapchain_images = try gfxstate.alloc.alloc(c.VkImage, swapchain_images_count);
        errdefer gfxstate.alloc.free(swapchain_images);

        try vkt(c.vkGetSwapchainImagesKHR(gfxstate.device, vk_swapchain, &swapchain_images_count, swapchain_images.ptr));

        const swapchain_image_views = try gfxstate.alloc.alloc(c.VkImageView, swapchain_images_count);
        errdefer gfxstate.alloc.free(swapchain_image_views);

        var swapchain_image_views_list = std.ArrayList(c.VkImageView).initBuffer(swapchain_image_views);
        errdefer for (swapchain_image_views_list.items) |image_view| { c.vkDestroyImageView(gfxstate.device, image_view, null); };

        for (swapchain_images) |img| {
            const view_create_info = c.VkImageViewCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = opt.format.format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            var swapchain_image_view: c.VkImageView = null;
            try vkt(c.vkCreateImageView(gfxstate.device, &view_create_info, null, &swapchain_image_view));
            errdefer c.vkDestroyImageView(gfxstate.device, swapchain_image_view, null);

            try swapchain_image_views_list.append(gfxstate.alloc, swapchain_image_view);
        }

        const image_available_semaphores = try gfxstate.alloc.alloc(gf.Semaphore, gfxstate.frames_in_flight());
        errdefer gfxstate.alloc.free(image_available_semaphores);

        var image_available_semaphores_list = std.ArrayList(gf.Semaphore).initBuffer(image_available_semaphores);
        errdefer for (image_available_semaphores_list.items) |s| { s.deinit(); };

        for (0..gfxstate.frames_in_flight()) |_| {
            const semaphore = try gf.Semaphore.init(.{});
            errdefer semaphore.deinit();

            try image_available_semaphores_list.append(gfxstate.alloc, semaphore);
        }

        const present_transition_semaphores = try gfxstate.alloc.alloc(gf.Semaphore, gfxstate.frames_in_flight());
        errdefer gfxstate.alloc.free(present_transition_semaphores);

        var present_transition_semaphores_list = std.ArrayList(gf.Semaphore).initBuffer(present_transition_semaphores);
        errdefer for (present_transition_semaphores_list.items) |s| { s.deinit(); };

        for (0..gfxstate.frames_in_flight()) |_| {
            const semaphore = try gf.Semaphore.init(.{});
            errdefer semaphore.deinit();

            try present_transition_semaphores_list.append(gfxstate.alloc, semaphore);
        }

        std.log.info("swapchain extent is {}", .{swapchain_extent});
        return .{
            .swapchain = vk_swapchain,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,

            .extent = swapchain_extent,
            .surface_format = opt.format,
            .present_mode = opt.present_mode,
            .image_available_semaphores = image_available_semaphores,
            .present_transition_semaphores = present_transition_semaphores,
        };
    }

    pub fn swapchain_image_count(self: *const SwapchainVulkan) u32 {
        return @intCast(self.swapchain_images.len);
    }
};

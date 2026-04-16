const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const FrameBufferVulkan = struct {
    vk_framebuffers: []c.VkFramebuffer,
    
    pub fn deinit(self: *const FrameBufferVulkan) void {
        const alloc = GfxStateVulkan.get().alloc;
        for (self.vk_framebuffers) |f| {
            c.vkDestroyFramebuffer(eng.get().gfx.platform.device, f, null);
        }
        alloc.free(self.vk_framebuffers);
    }

    pub fn init(info: gf.FrameBufferInfo) !FrameBufferVulkan {
        if (info.attachments.len == 0) { return error.NoAttachmentsProvided; }
        const render_pass = try info.render_pass.get();

        const alloc = GfxStateVulkan.get().alloc;

        const create_multiple_for_frames_in_flight = blk: {
            var swapchain_index: ?usize = null;
            for (info.attachments, 0..) |a, i| {
                switch (a) {
                    .SwapchainLDR, .SwapchainHDR, .SwapchainDepth, .View => {
                        swapchain_index = i;
                        break;
                    },
                    //else => {},
                }
            }
            break :blk (swapchain_index != null);
        };

        const swapchain_images_count = eng.get().gfx.platform.swapchain.swapchain_image_count();
        const framebuffers = try alloc.alloc(c.VkFramebuffer, if (create_multiple_for_frames_in_flight) swapchain_images_count else 1);
        errdefer alloc.free(framebuffers);

        const framebuffer_extent = vk.framebufferattachment_extent(info.attachments[0]);

        const attachments = try alloc.alloc(c.VkImageView, info.attachments.len);
        defer alloc.free(attachments);

        for (framebuffers, 0..) |*framebuffer, fidx| {
            for (info.attachments, 0..) |*a, aidx| {
                attachments[aidx] = switch (a.*) {
                    .SwapchainLDR => blk: {
                        break :blk GfxStateVulkan.get().swapchain.swapchain_image_views[fidx];
                    },
                    .SwapchainHDR => blk: {
                        const view = try gf.GfxState.get().default.hdr_image_view.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
                    },
                    .SwapchainDepth => blk: {
                        const view = try gf.GfxState.get().default.depth_view.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
                    },
                    .View => |v| blk: {
                        const view = try v.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
                    },
                };

                const attachment_extent = vk.framebufferattachment_extent(a.*);
                if (!attachment_extent.eql(framebuffer_extent)) {
                    return error.AttachmentsHaveDifferentExtents;
                }
            }

            const framebuffer_info = c.VkFramebufferCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = render_pass.platform.vk_render_pass,
                .pAttachments = @ptrCast(attachments.ptr),
                .attachmentCount = @intCast(attachments.len),
                .width = framebuffer_extent.width,
                .height = framebuffer_extent.height,
                .layers = framebuffer_extent.layers,
            };

            vkt(c.vkCreateFramebuffer(eng.get().gfx.platform.device, &framebuffer_info, null, framebuffer)) catch |err| {
                for (0..fidx) |i| {
                    c.vkDestroyFramebuffer(eng.get().gfx.platform.device, framebuffers[i], null);
                }
                return err;
            };
        }
        errdefer {
            for (framebuffers) |framebuffer| {
                c.vkDestroyFramebuffer(eng.get().gfx.platform.device, framebuffer, null);
            }
        }

        return FrameBufferVulkan {
            .vk_framebuffers = framebuffers,
        };
    }

    pub fn get_frame_framebuffer(self: *const FrameBufferVulkan) c.VkFramebuffer {
        const idx = @min(GfxStateVulkan.get().current_frame_index(), self.vk_framebuffers.len - 1);
        return self.vk_framebuffers[idx];
    }
};

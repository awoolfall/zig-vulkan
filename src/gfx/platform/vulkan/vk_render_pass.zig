const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const RenderPassVulkan = struct {
    const Self = @This();

    const SubpassRefInfo = struct {
        attachment_refs: []usize,
        depth_ref: ?usize,
    };
    
    vk_render_pass: c.VkRenderPass,
    vk_clear_values: []c.VkClearValue,

    subpass_attachment_refs: []SubpassRefInfo,

    pub fn deinit(self: *const Self) void {
        const alloc = GfxStateVulkan.get().alloc;

        c.vkDestroyRenderPass(GfxStateVulkan.get().device, self.vk_render_pass, null);

        alloc.free(self.vk_clear_values);

        for (self.subpass_attachment_refs) |r| {
            alloc.free(r.attachment_refs);
        }
        alloc.free(self.subpass_attachment_refs);
    }

    pub fn init(info: gf.RenderPassInfo) !RenderPassVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        var arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        const subpass_refs = try alloc.alloc(SubpassRefInfo, info.subpasses.len);
        errdefer alloc.free(subpass_refs);
        {
            var subpass_refs_list = std.ArrayList(SubpassRefInfo).initBuffer(subpass_refs);
            errdefer for (subpass_refs_list.items) |s| { alloc.free(s.attachment_refs); };

            for (info.subpasses) |subpass| {
                const subpass_attachment_refs = try alloc.alloc(usize, subpass.attachments.len);
                errdefer alloc.free(subpass_attachment_refs);

                for (subpass.attachments, 0..) |subpass_attachment_name, subpass_aidx| {
                    const attachment_idx = find_attachment_by_name(subpass_attachment_name, info.attachments) catch {
                        return error.UnableToFindColourAttachmentName;
                    };
                    subpass_attachment_refs[subpass_aidx] = attachment_idx;
                }

                const depth_ref = if (subpass.depth_attachment) |depth_name| depth_blk: {
                    const attachment_idx = find_attachment_by_name(depth_name, info.attachments) catch {
                        return error.UnableToFindDepthAttachmentName;
                    };
                    break :depth_blk attachment_idx;
                } else null;

                try subpass_refs_list.appendBounded(SubpassRefInfo {
                    .attachment_refs = subpass_attachment_refs,
                    .depth_ref = depth_ref,
                });
            }

            std.debug.assert(subpass_refs_list.items.len == info.subpasses.len);
        }

        var subpass_descriptions = try arena.alloc(c.VkSubpassDescription, subpass_refs.len);
        defer arena.free(subpass_descriptions);

        for (subpass_refs, 0..) |ref, idx| {
            var attachment_refs = try arena.alloc(c.VkAttachmentReference, ref.attachment_refs.len);
            // freed by arena allocator
            
            for (ref.attachment_refs, 0..) |aidx, ridx| {
                attachment_refs[ridx] = .{
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, // @TODO: depth? other layouts?
                    .attachment = @intCast(aidx),
                };
            }

            var depth_attachment_ref = if (ref.depth_ref) |r| c.VkAttachmentReference {
                .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                .attachment = @intCast(r),
            } else null;

            subpass_descriptions[idx] = c.VkSubpassDescription{
                .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, // @TODO: other?
                .pColorAttachments = @ptrCast(attachment_refs.ptr),
                .colorAttachmentCount = @intCast(attachment_refs.len),
                .pDepthStencilAttachment = if (depth_attachment_ref) |*d| d else null,
                // @TODO: resolve attachments, preserve attachments, etc.
            };
        }

        var attachment_descriptions = try arena.alloc(c.VkAttachmentDescription, info.attachments.len);
        defer arena.free(attachment_descriptions);

        var vk_clear_values = try alloc.alloc(c.VkClearValue, info.attachments.len);
        errdefer alloc.free(vk_clear_values);

        for (info.attachments, 0..) |*a, idx| {
            attachment_descriptions[idx] = c.VkAttachmentDescription {
                .format = vk.textureformat_to_vulkan(a.format),
                .initialLayout = vk.imagelayout_to_vulkan(a.initial_layout),
                .finalLayout = vk.imagelayout_to_vulkan(a.final_layout),
                .loadOp = vk.loadop_to_vulkan(a.load_op),
                .storeOp = vk.storeop_to_vulkan(a.store_op),
                .stencilLoadOp = vk.loadop_to_vulkan(a.stencil_load_op),
                .stencilStoreOp = vk.storeop_to_vulkan(a.stencil_store_op),
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
            };

            if (a.load_op == .Clear) {
                vk_clear_values[idx] = vk.formatclearvalue_to_vulkan(a.format, a.clear_value);
            }
        }

        var vk_dependencies = try alloc.alloc(c.VkSubpassDependency, info.dependencies.len);
        defer alloc.free(vk_dependencies);

        for (info.dependencies, 0..) |d, idx| {
            vk_dependencies[idx] = c.VkSubpassDependency {
                .srcSubpass = if (d.src_subpass) |s| s else c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = d.dst_subpass,
                .srcStageMask = vk.pipelinestageflags_to_vulkan(d.src_stage_mask),
                .srcAccessMask = vk.accessflags_to_vulkan(d.src_access_mask),
                .dstStageMask = vk.pipelinestageflags_to_vulkan(d.dst_stage_mask),
                .dstAccessMask = vk.accessflags_to_vulkan(d.dst_access_mask),
            };
        }

        const render_pass_info = c.VkRenderPassCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,

            .pAttachments = @ptrCast(attachment_descriptions.ptr),
            .attachmentCount = @intCast(attachment_descriptions.len),

            .pSubpasses = @ptrCast(subpass_descriptions.ptr),
            .subpassCount = @intCast(subpass_descriptions.len),

            .pDependencies = @ptrCast(vk_dependencies.ptr),
            .dependencyCount = @intCast(vk_dependencies.len),
        };

        var vk_render_pass: c.VkRenderPass = undefined;
        try vkt(c.vkCreateRenderPass(eng.get().gfx.platform.device, &render_pass_info, null, &vk_render_pass));
        errdefer c.vkDestroyRenderPass(eng.get().gfx.platform.device, vk_render_pass, null);

        return RenderPassVulkan {
            .vk_render_pass = vk_render_pass,
            .vk_clear_values = vk_clear_values,
            .subpass_attachment_refs = subpass_refs,
        };
    }

    inline fn find_attachment_by_name(name: []const u8, attachments: []const gf.AttachmentInfo) !usize {
        return for (attachments, 0..) |attachment, aidx| {
            if (std.mem.eql(u8, attachment.name, name)) {
                break aidx;
            }
        } else return error.UnableToFindAttachmentWithName;
    }
};

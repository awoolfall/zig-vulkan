const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const CommandBufferVulkan = struct {
    const Self = @This();

    vk_pool: c.VkCommandPool,
    vk_command_buffer: c.VkCommandBuffer,

    bound_pipeline: union(enum) {
        None: void,
        Graphics: gf.GraphicsPipeline.Ref,
        Compute: gf.ComputePipeline.Ref,
    } = .None,

    pub fn deinit(self: *const Self) void {
        c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, 1, &self.vk_command_buffer);
    }

    pub fn reset(self: *Self) !void {
        try vkt(c.vkResetCommandBuffer(self.vk_command_buffer, 0));
    }

    pub fn cmd_begin(self: *Self, info: gf.CommandBuffer.BeginInfo) !void {
        const begin_info = c.VkCommandBufferBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.commandbufferbeginflags_to_vulkan(info),
        };

        try vkt(c.vkBeginCommandBuffer(self.vk_command_buffer, &begin_info));
    }

    pub fn cmd_end(self: *Self) !void {
        try vkt(c.vkEndCommandBuffer(self.vk_command_buffer));
    }

    fn subpasscontents_to_vulkan(subpasscontents: gf.CommandBuffer.SubpassContents) c.VkSubpassContents {
        return switch (subpasscontents) {
            .Inline => c.VK_SUBPASS_CONTENTS_INLINE,
            .SecondaryCommandBuffers => c.VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS,
        };
    }

    pub fn cmd_begin_render_pass(self: *Self, info: gf.CommandBuffer.BeginRenderPassInfo) void {
        const render_pass = info.render_pass.get() catch return;
        const framebuffer = info.framebuffer.get() catch return;
        
        const begin_info = c.VkRenderPassBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass.platform.vk_render_pass,
            .framebuffer = framebuffer.platform.get_frame_framebuffer(),
            .pClearValues = @ptrCast(render_pass.platform.vk_clear_values.ptr),
            .clearValueCount = @intCast(render_pass.platform.vk_clear_values.len),
            .renderArea = vk.rect_to_vulkan(info.render_area),
        };

        c.vkCmdBeginRenderPass(self.vk_command_buffer, &begin_info, subpasscontents_to_vulkan(info.subpass_contents));
    }

    pub fn cmd_next_subpass(self: *Self, info: gf.CommandBuffer.NextSubpassInfo) void {
        c.vkCmdNextSubpass(self.vk_command_buffer, subpasscontents_to_vulkan(info.subpass_contents));
    }

    pub fn cmd_end_render_pass(self: *Self) void {
        c.vkCmdEndRenderPass(self.vk_command_buffer);
    }

    pub fn cmd_bind_graphics_pipeline(self: *Self, pipeline: gf.GraphicsPipeline.Ref) void {
        const p = pipeline.get() catch return;

        self.bound_pipeline = .{ .Graphics = pipeline };
        c.vkCmdBindPipeline(self.vk_command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, p.platform.vk_graphics_pipeline);
    }

    pub fn cmd_bind_compute_pipeline(self: *Self, pipeline: gf.ComputePipeline.Ref) void {
        const p = pipeline.get() catch return;

        self.bound_pipeline = .{ .Compute = pipeline, };
        c.vkCmdBindPipeline(self.vk_command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.platform.vk_compute_pipeline);
    }

    const max_vk_viewports = 6;
    pub fn cmd_set_viewports(self: *Self, info: gf.CommandBuffer.SetViewportsInfo) void {
        std.debug.assert(info.viewports.len <= max_vk_viewports);

        var vk_viewports: [max_vk_viewports]c.VkViewport = undefined;
        for (info.viewports, 0..) |v, idx| {
            vk_viewports[idx] = c.VkViewport {
                .x = v.top_left_x,
                .y = v.top_left_y,
                .width = v.width,
                .height = v.height,
                .minDepth = v.min_depth,
                .maxDepth = v.max_depth,
            };
        }

        c.vkCmdSetViewport(
            self.vk_command_buffer, 
            info.first_viewport, 
            @intCast(info.viewports.len),
            @ptrCast(vk_viewports[0..].ptr)
        );
    }

    pub fn cmd_set_scissors(self: *Self, info: gf.CommandBuffer.SetScissorsInfo) void {
        std.debug.assert(info.scissors.len <= max_vk_viewports);

        var vk_scissors: [max_vk_viewports]c.VkRect2D = undefined;
        for (info.scissors, 0..) |s, idx| {
            vk_scissors[idx] = vk.rect_to_vulkan(s);
        }
        c.vkCmdSetScissor(
            self.vk_command_buffer,
            info.first_scissor,
            @intCast(info.scissors.len),
            @ptrCast(vk_scissors[0..].ptr)
        );
    }

    pub fn cmd_bind_vertex_buffers(self: *Self, info: gf.CommandBuffer.BindVertexBuffersInfo) void {
        const max_vertex_buffers = 16;
        std.debug.assert(info.buffers.len <= max_vertex_buffers);

        var vk_buffers: [max_vertex_buffers]c.VkBuffer = undefined;
        var vk_device_sizes: [max_vertex_buffers]c.VkDeviceSize = undefined;
        for (info.buffers, 0..) |b, idx| {
            const buffer = b.buffer.get() catch unreachable;
            vk_buffers[idx] = buffer.platform.get_frame_vk_buffer();
            vk_device_sizes[idx] = b.offset;
        }
        c.vkCmdBindVertexBuffers(
            self.vk_command_buffer,
            info.first_binding,
            @intCast(info.buffers.len),
            @ptrCast(vk_buffers[0..].ptr),
            @ptrCast(vk_device_sizes[0..].ptr)
        );
    }

    pub fn cmd_bind_index_buffer(self: *Self, info: gf.CommandBuffer.BindIndexBufferInfo) void {
        const buffer = info.buffer.get() catch unreachable;
        c.vkCmdBindIndexBuffer(
            self.vk_command_buffer,
            buffer.platform.get_frame_vk_buffer(),
            info.offset,
            vk.indexformat_to_vulkan(info.index_format)
        );
    }

    pub fn cmd_bind_descriptor_sets(self: *Self, info: gf.CommandBuffer.BindDescriptorSetInfo) void {
        const max_descriptor_sets = 16;
        std.debug.assert(info.descriptor_sets.len <= 16);

        var vk_descriptor_sets: [max_descriptor_sets]c.VkDescriptorSet = undefined;
        for (info.descriptor_sets, 0..) |s, idx| {
            const set = s.get() catch unreachable;
            set.platform.perform_updates_if_required() catch |err| {
                std.log.warn("Unable to perform updates on the bound descriptor set: {}", .{err});
            };

            vk_descriptor_sets[idx] = set.platform.get_frame_set();
        }

        const vk_bind_point: c.VkPipelineBindPoint, const vk_pipeline_layout = switch (self.bound_pipeline) {
            .Graphics => |p| .{ c.VK_PIPELINE_BIND_POINT_GRAPHICS, (p.get() catch unreachable).platform.vk_pipeline_layout },
            .Compute => |p| .{ c.VK_PIPELINE_BIND_POINT_COMPUTE, (p.get() catch unreachable).platform.vk_pipeline_layout },
            .None => {
                std.log.warn("Attempted to bind descriptor sets when no pipeline was bound.", .{});
                return;
            },
        };

        c.vkCmdBindDescriptorSets(
            self.vk_command_buffer,
            vk_bind_point,
            vk_pipeline_layout,
            info.first_binding,
            @intCast(info.descriptor_sets.len),
            @ptrCast(vk_descriptor_sets[0..].ptr),
            @intCast(info.dynamic_offsets.len),
            @ptrCast(info.dynamic_offsets.ptr)
        );
    }

    pub fn cmd_push_constants(self: *Self, info: gf.CommandBuffer.PushConstantsInfo) void {
        const vk_pipeline_layout = switch (self.bound_pipeline) {
            .Graphics => |p| (p.get() catch unreachable).platform.vk_pipeline_layout,
            .Compute => |p| (p.get() catch unreachable).platform.vk_pipeline_layout,
            .None => {
                std.log.warn("Attempted to push constants when no pipeline was bound.", .{});
                return;
            },
        };

        c.vkCmdPushConstants(
            self.vk_command_buffer,
            vk_pipeline_layout,
            vk.shaderstageflags_to_vulkan(info.shader_stages),
            info.offset,
            @intCast(info.data.len),
            @ptrCast(info.data.ptr)
        );
    }

    pub fn cmd_draw(self: *Self, info: gf.CommandBuffer.DrawInfo) void {
        c.vkCmdDraw(
            self.vk_command_buffer,
            info.vertex_count,
            info.instance_count,
            info.first_vertex,
            info.first_instance
        );
    }

    pub fn cmd_draw_indexed(self: *Self, info: gf.CommandBuffer.DrawIndexedInfo) void {
        c.vkCmdDrawIndexed(
            self.vk_command_buffer,
            info.index_count,
            info.instance_count,
            info.first_index,
            info.vertex_offset,
            info.first_instance
        );
    }

    pub fn cmd_pipeline_barrier(self: *Self, info: gf.CommandBuffer.PipelineBarrierInfo) void {
        const max_barriers_per_type = 8;
        std.debug.assert(info.memory_barriers.len < max_barriers_per_type);
        std.debug.assert(info.buffer_barriers.len < max_barriers_per_type);
        std.debug.assert(info.image_barriers.len < max_barriers_per_type);

        var vk_memory_barriers: [max_barriers_per_type]c.VkMemoryBarrier = undefined;
        var vk_buffer_barriers: [max_barriers_per_type]c.VkBufferMemoryBarrier = undefined;
        var vk_image_barriers: [max_barriers_per_type]c.VkImageMemoryBarrier = undefined;

        for (info.memory_barriers, 0..) |b, idx| {
            vk_memory_barriers[idx] = c.VkMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                .srcAccessMask = vk.accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = vk.accessflags_to_vulkan(b.dst_access_mask),
            };
        }

        for (info.buffer_barriers, 0..) |b, idx| {
            const buffer = b.buffer.get() catch unreachable;
            vk_buffer_barriers[idx] = c.VkBufferMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                .buffer = buffer.platform.get_frame_vk_buffer(),
                .offset = b.offset,
                .size = b.size,
                .srcAccessMask = vk.accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = vk.accessflags_to_vulkan(b.dst_access_mask),
                .srcQueueFamilyIndex = if (b.src_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = if (b.dst_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
            };
        }

        for (info.image_barriers, 0..) |b, idx| {
            const image = b.image.get() catch unreachable;
            vk_image_barriers[idx] = c.VkImageMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .image = image.platform.get_frame_image().vk_image, // TODO allow selecting inner image?
                .oldLayout = if (b.old_layout) |l| vk.imagelayout_to_vulkan(l) else c.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = if (b.new_layout) |l| vk.imagelayout_to_vulkan(l) else c.VK_IMAGE_LAYOUT_UNDEFINED,
                .srcAccessMask = vk.accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = vk.accessflags_to_vulkan(b.dst_access_mask),
                .srcQueueFamilyIndex = if (b.src_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = if (b.dst_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .subresourceRange = .{
                    .aspectMask =   if (!image.info.format.is_depth()) c.VK_IMAGE_ASPECT_COLOR_BIT
                                    else c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT,
                    .baseMipLevel = b.subresource_range.base_mip_level,
                    .levelCount = 
                        if (b.subresource_range.mip_level_count >= image.info.mip_levels - b.subresource_range.base_mip_level) c.VK_REMAINING_MIP_LEVELS
                        else b.subresource_range.mip_level_count,
                    .baseArrayLayer = b.subresource_range.base_array_layer,
                    .layerCount =
                        if (b.subresource_range.array_layer_count >= image.info.array_length - b.subresource_range.base_array_layer) c.VK_REMAINING_ARRAY_LAYERS
                        else b.subresource_range.array_layer_count,
                },
            };
        }

        c.vkCmdPipelineBarrier(
            self.vk_command_buffer, 
            vk.pipelinestageflags_to_vulkan(info.src_stage), 
            vk.pipelinestageflags_to_vulkan(info.dst_stage), 
            0, 
            @intCast(info.memory_barriers.len), @ptrCast(vk_memory_barriers[0..].ptr),
            @intCast(info.buffer_barriers.len), @ptrCast(vk_buffer_barriers[0..].ptr),
            @intCast(info.image_barriers.len), @ptrCast(vk_image_barriers[0..].ptr),
        );
    }

    pub fn cmd_copy_image_to_buffer(self: *Self, info: gf.CommandBuffer.CopyImageToBufferInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkBufferImageCopy).initCapacity(alloc, 16)
            catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkBufferImageCopy {
                .bufferOffset = copy_region.buffer_offset,
                .bufferRowLength = copy_region.buffer_row_length,
                .bufferImageHeight = copy_region.buffer_image_height,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, // TODO depth aspect?
                    .baseArrayLayer = copy_region.base_array_layer,
                    .layerCount = copy_region.layer_count,
                    .mipLevel = copy_region.mip_level,
                },
                .imageOffset = .{
                    .x = copy_region.image_offset[0],
                    .y = copy_region.image_offset[1],
                    .z = copy_region.image_offset[2],
                },
                .imageExtent = .{
                    .width = copy_region.image_extent[0],
                    .height = copy_region.image_extent[1],
                    .depth = copy_region.image_extent[2],
                },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const image = info.image.get() catch return;
        const buffer = info.buffer.get() catch return;

        c.vkCmdCopyImageToBuffer(
            self.vk_command_buffer,
            image.platform.get_frame_image().vk_image, // TODO allow selection of specific internal image. fix? using frame image should be recent enough (and prevent stalls, maybe)
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            buffer.platform.get_frame_vk_buffer(),
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_copy_buffer_to_image(self: *Self, info: gf.CommandBuffer.CopyBufferToImageInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkBufferImageCopy).initCapacity(alloc, 16)
            catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkBufferImageCopy {
                .bufferOffset = copy_region.buffer_offset,
                .bufferRowLength = copy_region.buffer_row_length,
                .bufferImageHeight = copy_region.buffer_image_height,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, // TODO depth aspect?
                    .baseArrayLayer = copy_region.base_array_layer,
                    .layerCount = copy_region.layer_count,
                    .mipLevel = copy_region.mip_level,
                },
                .imageOffset = .{
                    .x = copy_region.image_offset[0],
                    .y = copy_region.image_offset[1],
                    .z = copy_region.image_offset[2],
                },
                .imageExtent = .{
                    .width = copy_region.image_extent[0],
                    .height = copy_region.image_extent[1],
                    .depth = copy_region.image_extent[2],
                },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const image = info.image.get() catch return;
        const buffer = info.buffer.get() catch return;

        c.vkCmdCopyBufferToImage(
            self.vk_command_buffer,
            buffer.platform.get_frame_vk_buffer(),
            image.platform.get_frame_image().vk_image, // TODO allow selection of specific internal image. fix? using frame image should be recent enough (and prevent stalls, maybe)
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_copy_image_to_image(self: *Self, info: gf.CommandBuffer.CopyImageToImageInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkImageCopy).initCapacity(alloc, 16) catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkImageCopy {
                .srcSubresource = .{
                    .aspectMask = vk.imageaspect_to_vulkan(copy_region.src_subresource.aspect_mask),
                    .baseArrayLayer = copy_region.src_subresource.base_array_layer,
                    .layerCount = copy_region.src_subresource.array_layer_count,
                    .mipLevel = copy_region.src_subresource.mip_level,
                },
                .srcOffset = .{ .x = copy_region.src_offset[0], .y = copy_region.src_offset[1], .z = copy_region.src_offset[2], },
                .dstSubresource = .{
                    .aspectMask = vk.imageaspect_to_vulkan(copy_region.dst_subresource.aspect_mask),
                    .baseArrayLayer = copy_region.dst_subresource.base_array_layer,
                    .layerCount = copy_region.dst_subresource.array_layer_count,
                    .mipLevel = copy_region.dst_subresource.mip_level,
                },
                .dstOffset = .{ .x = copy_region.dst_offset[0], .y = copy_region.dst_offset[1], .z = copy_region.dst_offset[2], },
                .extent = .{ .width = copy_region.extent[0], .height = copy_region.extent[1], .depth = copy_region.extent[2], },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const src_image = info.src_image.get() catch return;
        const dst_image = info.dst_image.get() catch return;

        c.vkCmdCopyImage(
            self.vk_command_buffer,
            src_image.platform.get_frame_image().vk_image,
            vk.imagelayout_to_vulkan(info.src_image_layout),
            dst_image.platform.get_frame_image().vk_image,
            vk.imagelayout_to_vulkan(info.dst_image_layout),
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_dispatch(self: *Self, info: gf.CommandBuffer.DispatchInfo) void {
        c.vkCmdDispatch(
            self.vk_command_buffer, 
            info.group_count_x, 
            info.group_count_y, 
            info.group_count_z
        );
    }
};

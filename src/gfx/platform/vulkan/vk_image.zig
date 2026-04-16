const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;
const BufferVulkan = @import("vk_buffer.zig").BufferVulkan;

pub const ImageVulkan = struct {
    const Self = @This();

    const ImageData = struct {
        vk_image: c.VkImage,
        vk_device_memory: c.VkDeviceMemory,
    };

    images: []ImageData,
    vk_format: c.VkFormat,
    format: gf.ImageFormat,

    pub fn deinit(self: *const Self) void {
        for (self.images) |i| {
            c.vkDestroyImage(GfxStateVulkan.get().device, i.vk_image, null);
            c.vkFreeMemory(GfxStateVulkan.get().device, i.vk_device_memory, null);
        }
        GfxStateVulkan.get().alloc.free(self.images);
    }

    pub fn init(
        info: gf.ImageInfo,
        data: ?[]const u8,
    ) !Self {
        std.debug.assert(data == null or (data != null and info.dst_layout != .Undefined));

        const alloc = GfxStateVulkan.get().alloc;

        var usage_flags_plus = info.usage_flags;
        if (data != null) {
            usage_flags_plus.TransferDst = true;
        }
        if (data != null and info.mip_levels > 1) {
            usage_flags_plus.TransferSrc = true;
        }
        const vk_usage_flags = vk.convert_texture_usage_flags_to_vulkan(usage_flags_plus);

        const vk_format = vk.textureformat_to_vulkan(info.format);

        const image_count = 
            if (usage_flags_plus.RenderTarget or usage_flags_plus.DepthStencil) GfxStateVulkan.get().frames_in_flight()
            else 1;

        const images = try alloc.alloc(ImageData, image_count);
        errdefer alloc.free(images);

        var images_list = std.ArrayList(ImageData).initBuffer(images);
        errdefer for (images_list.items) |i| {
            c.vkFreeMemory(GfxStateVulkan.get().device, i.vk_device_memory, null);
            c.vkDestroyImage(GfxStateVulkan.get().device, i.vk_image, null);
        };

        const vk_image_type: c.VkImageType = if (info.depth <= 1) c.VK_IMAGE_TYPE_2D else c.VK_IMAGE_TYPE_3D; 

        for (0..image_count) |_| {
            const image_info = c.VkImageCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .format = vk_format,
                .imageType = vk_image_type,
                .extent = c.VkExtent3D {
                    .width = info.width,
                    .height = info.height,
                    .depth = @max(info.depth, 1),
                },
                .mipLevels = info.mip_levels,
                .arrayLayers = info.array_length,
                .tiling = c.VK_IMAGE_TILING_OPTIMAL,
                .initialLayout = vk.imagelayout_to_vulkan(.Undefined),
                .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .usage = vk_usage_flags,
            };

            var vk_image: c.VkImage = undefined;
            try vkt(c.vkCreateImage(GfxStateVulkan.get().device, &image_info, null, &vk_image));
            errdefer c.vkDestroyImage(GfxStateVulkan.get().device, vk_image, null);

            var memory_requirements: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(GfxStateVulkan.get().device, vk_image, &memory_requirements);

            const alloc_info = c.VkMemoryAllocateInfo {
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = memory_requirements.size,
                .memoryTypeIndex = try vk.find_vulkan_memory_type(memory_requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            };

            // TODO better memory allocation strategy
            var vk_device_memory: c.VkDeviceMemory = undefined;
            try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &alloc_info, null, &vk_device_memory));
            errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

            try vkt(c.vkBindImageMemory(GfxStateVulkan.get().device, vk_image, vk_device_memory, 0));

            try images_list.append(alloc, .{
                .vk_image = vk_image,
                .vk_device_memory = vk_device_memory,
            });
        }

        var self = Self {
            .images = images,
            .vk_format = vk_format,
            .format = info.format,
        };

        if (data) |d| {
            const buffer_length = info.width * info.height * info.depth * info.array_length * info.format.byte_width();
            const staging_buffer = try BufferVulkan.init_staging(@intCast(buffer_length));
            defer staging_buffer.deinit();

            {
                var mapped_buffer = try staging_buffer.map(.{ .write = .Infrequent, });
                defer mapped_buffer.unmap();

                const mapped_slice = mapped_buffer.data_array(u8, buffer_length);
                @memcpy(mapped_slice, d);
            }

            for (0..images.len) |image_idx| {
                try self.transition_layout(image_idx, .Undefined, .TransferDstOptimal);

                {
                    var command_buffer = try vk.begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);
                    defer vk.end_single_time_command_buffer(&command_buffer, null);

                    const region = c.VkBufferImageCopy {
                        .bufferOffset = 0,
                        .bufferRowLength = 0,
                        .bufferImageHeight = 0,

                        .imageSubresource = .{
                            .aspectMask = 
                                if (self.format.is_depth()) c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT
                                else c.VK_IMAGE_ASPECT_COLOR_BIT,
                            .mipLevel = 0,
                            .baseArrayLayer = 0,
                            .layerCount = 1,
                        },

                        .imageOffset = .{ .x = 0, .y = 0, .z = 0, },
                        .imageExtent = .{
                            .width = info.width,
                            .height = info.height,
                            .depth = info.depth,
                        }
                    };

                    c.vkCmdCopyBufferToImage(
                        command_buffer.platform.vk_command_buffer,
                        staging_buffer.get_frame_vk_buffer(),
                        images[image_idx].vk_image,
                        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                        1,
                        &region
                    );

                    // generate mipmaps
                    var mip_width: i32 = @intCast(info.width);
                    var mip_height: i32 = @intCast(info.height);

                    for (1..info.mip_levels) |mip_level| {
                        const barrier0_info = c.VkImageMemoryBarrier {
                            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                            .image = images[image_idx].vk_image,
                            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
                            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
                            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .subresourceRange = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .baseMipLevel = @intCast(mip_level - 1),
                                .levelCount = 1,
                            }
                        };

                        c.vkCmdPipelineBarrier(
                            command_buffer.platform.vk_command_buffer,
                            c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                            0, null,
                            0, null,
                            1, @ptrCast(&barrier0_info)
                        );

                        const blit = c.VkImageBlit {
                            .srcOffsets = .{
                                .{ .x = 0, .y = 0, .z = 0, },
                                .{ .x = mip_width, .y = mip_height, .z = 1 },
                            },
                            .dstOffsets = .{
                                .{ .x = 0, .y = 0, .z = 0 },
                                .{ .x = if (mip_width > 1) @divTrunc(mip_width, 2) else 1, .y = if (mip_height > 1) @divTrunc(mip_height, 2) else 1, .z = 1 },
                            },
                            .srcSubresource = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .mipLevel = @intCast(mip_level - 1),
                            },
                            .dstSubresource = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .mipLevel = @intCast(mip_level),
                            }
                        };

                        c.vkCmdBlitImage(
                            command_buffer.platform.vk_command_buffer,
                            images[image_idx].vk_image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            images[image_idx].vk_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            1, &blit,
                            c.VK_FILTER_LINEAR
                        );

                        const barrier1_info = c.VkImageMemoryBarrier {
                            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                            .image = images[image_idx].vk_image,
                            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
                            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
                            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .subresourceRange = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .baseMipLevel = @intCast(mip_level - 1),
                                .levelCount = 1,
                            }
                        };

                        c.vkCmdPipelineBarrier(
                            command_buffer.platform.vk_command_buffer,
                            c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, 0,
                            0, null,
                            0, null,
                            1, @ptrCast(&barrier1_info)
                        );

                        if (mip_width > 1) { mip_width = @divTrunc(mip_width, 2); }
                        if (mip_height > 1) { mip_height = @divTrunc(mip_height, 2); }
                    }
                }
            }
        }

        for (0..images.len) |image_idx| {
            try self.transition_layout(
                image_idx,
                if (data) |_| .TransferDstOptimal else .Undefined,
                info.dst_layout
            );
        }

        return self;
    }

    pub inline fn get_frame_image(self: *const Self) *const ImageData {
        const idx = GfxStateVulkan.get().current_frame_index();
        return &self.images[@as(usize, @intCast(idx)) % self.images.len];
    }

    pub fn map(self: *const Self, options: gf.Image.MapOptions) !MappedImage {
        _ = self;
        _ = options;
        return error.NotImplemented;
    }

    pub const MappedImage = struct {

        pub fn unmap(self: *const MappedImage) void {
            _ = self;
        }

        pub fn data(self: *const MappedImage, comptime Type: type) [*]align(16)Type {
            _ = self;
            unreachable;
        }
    };

    fn transition_layout(
        self: *Self, 
        image_index: usize,
        old_layout: gf.ImageLayout, 
        new_layout: gf.ImageLayout,
    ) !void {
        var cmd = try vk.begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);
        defer vk.end_single_time_command_buffer(&cmd, null);

        var src_access: c.VkAccessFlags = 0;
        var dst_access: c.VkAccessFlags = 0;

        var src_stage: c.VkPipelineStageFlags = 0;
        var dst_stage: c.VkPipelineStageFlags = 0;

        switch (old_layout) {
            .Undefined => {
                src_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            },
            .TransferDstOptimal => {
                src_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            else => unreachable,
        }

        switch (new_layout) {
            .ShaderReadOnlyOptimal => {
                dst_access = c.VK_ACCESS_SHADER_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .TransferDstOptimal => {
                dst_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            .DepthStencilAttachmentOptimal => {
                dst_access = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .DepthStencilReadOnlyOptimal => {
                dst_access = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .ColorAttachmentOptimal => {
                dst_access = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            },
            .PresentSrc => {
                dst_access = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .General => {
                dst_access = c.VK_ACCESS_SHADER_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            },
            .Undefined => unreachable,
            else => unreachable,
        }

        const image_barrier = c.VkImageMemoryBarrier {
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .image = self.images[image_index].vk_image,
            .oldLayout = vk.imagelayout_to_vulkan(old_layout),
            .newLayout = vk.imagelayout_to_vulkan(new_layout),
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .subresourceRange = .{
                .aspectMask = 
                    if (self.format.is_depth()) c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT
                    else c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = c.VK_REMAINING_MIP_LEVELS,
                .baseArrayLayer = 0,
                .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
            },
        };
        c.vkCmdPipelineBarrier(
            cmd.platform.vk_command_buffer, 
            src_stage, 
            dst_stage, 
            0, 
            0, null,
            0, null,
            1, &image_barrier
        );
    }
};
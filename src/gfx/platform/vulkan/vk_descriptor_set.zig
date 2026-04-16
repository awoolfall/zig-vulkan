const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const DescriptorSetVulkan = struct {
    const UpdateWriteInfo = struct {
        const BitSetMaxSize = 16;
        const UpdatedSetsBitSet = std.bit_set.IntegerBitSet(BitSetMaxSize);

        write: gf.DescriptorSetUpdateWriteInfo,
        updated_sets: UpdatedSetsBitSet = UpdatedSetsBitSet.initEmpty(),
    };

    vk_sets: []c.VkDescriptorSet,
    vk_pool: c.VkDescriptorPool,
    can_free_individual_sets: bool, // TODO free individual sets?

    write_infos: std.AutoHashMap(u32, UpdateWriteInfo),
    completed_update_propogations: bool = false,

    pub fn deinit(self: *DescriptorSetVulkan) void {
        const alloc = GfxStateVulkan.get().alloc;

        if (self.can_free_individual_sets) {
            vkt(c.vkFreeDescriptorSets(GfxStateVulkan.get().device, self.vk_pool, @intCast(self.vk_sets.len), @ptrCast(self.vk_sets.ptr))) catch |err| {
                std.log.err("Unable to free descriptor sets: {}", .{err});
            };
        }
        alloc.free(self.vk_sets);
        
        var write_infos_iter = self.write_infos.valueIterator();
        while (write_infos_iter.next()) |write_info| {
            deinit_update_write_info(&write_info.write);
        }
        self.write_infos.deinit();
    }

    pub fn init(vk_pool: c.VkDescriptorPool, vk_sets: []const c.VkDescriptorSet, can_free_individual_sets: bool) !DescriptorSetVulkan {
        std.debug.assert(GfxStateVulkan.get().frames_in_flight() < UpdateWriteInfo.BitSetMaxSize);

        const owned_vk_sets = try GfxStateVulkan.get().alloc.dupe(c.VkDescriptorSet, vk_sets);
        errdefer GfxStateVulkan.get().alloc.free(owned_vk_sets);

        return .{
            .vk_sets = owned_vk_sets,
            .vk_pool = vk_pool,
            .can_free_individual_sets = can_free_individual_sets,
            .write_infos = std.AutoHashMap(u32, UpdateWriteInfo).init(GfxStateVulkan.get().alloc),
        };
    }

    fn deinit_update_write_info(info: *const gf.DescriptorSetUpdateWriteInfo) void {
        const alloc = GfxStateVulkan.get().alloc;

        switch (info.data) {
            .UniformBufferArray => |a| { alloc.free(a); },
            .StorageBufferArray => |a| { alloc.free(a); },
            .ImageViewArray => |a| { alloc.free(a); },
            .SamplerArray => |a| { alloc.free(a); },
            .ImageViewAndSamplerArray => |a| { alloc.free(a); },
            else => {},
        }
    }

    fn dupe_update_info(info: gf.DescriptorSetUpdateWriteInfo) !gf.DescriptorSetUpdateWriteInfo {
        const alloc = GfxStateVulkan.get().alloc;

        var duped_info = info;

        switch (info.data) {
            .UniformBufferArray => |a| {
                duped_info.data = .{ .UniformBufferArray = try alloc.dupe(gf.DescriptorSetWriteBufferInfo, a), };
            },
            .StorageBufferArray => |a| {
                duped_info.data = .{ .StorageBufferArray = try alloc.dupe(gf.DescriptorSetWriteBufferInfo, a), };
            },
            .ImageViewArray => |a| {
                duped_info.data = .{ .ImageViewArray = try alloc.dupe(gf.ImageView.Ref, a), };
            },
            .SamplerArray => |a| {
                duped_info.data = .{ .SamplerArray = try alloc.dupe(gf.Sampler.Ref, a), };
            },
            .ImageViewAndSamplerArray => |a| {
                duped_info.data = .{ .ImageViewAndSamplerArray = try alloc.dupe(gf.ImageViewAndSampler, a), };
            },
            else => {},
        }

        return duped_info;
    }

    pub fn get_frame_set(self: *const DescriptorSetVulkan) c.VkDescriptorSet {
        return self.vk_sets[@min(GfxStateVulkan.get().current_frame_index(), self.vk_sets.len)];
    }

    pub fn update(self: *DescriptorSetVulkan, info: gf.DescriptorSetUpdateInfo) !void {
        for (info.writes) |write| {
            const duped_write = dupe_update_info(write) catch |err| {
                std.log.warn("Unable to dupe descriptor write info: {}", .{err});
                continue;
            };

            const maybe_fetched_write_info = self.write_infos.fetchPut(
                duped_write.binding,
                UpdateWriteInfo { .write = duped_write, }
            ) catch |err| {
                std.log.warn("Unable to put new write info into descriptor set: {}", .{err});
                continue;
            };

            if (maybe_fetched_write_info) |*fetched_write_info| {
                deinit_update_write_info(&fetched_write_info.value.write);
            }
        }

        self.completed_update_propogations = false;
    }

    pub fn reapply_all_stored_writes(self: *DescriptorSetVulkan) void {
        var write_info_iter = self.write_infos.valueIterator();
        while (write_info_iter.next()) |write_info| {
            write_info.updated_sets = UpdateWriteInfo.UpdatedSetsBitSet.initEmpty();
        }

        self.completed_update_propogations = false;
    }

    pub fn perform_updates_if_required(self: *DescriptorSetVulkan) !void {
        if (!self.completed_update_propogations) {
            try self.perform_updates_on_current_frame_set();
        }
    }

    fn perform_updates_on_current_frame_set(self: *DescriptorSetVulkan) !void {
        const alloc = GfxStateVulkan.get().alloc;
        const cfi = GfxStateVulkan.get().current_frame_index();
        const fif = GfxStateVulkan.get().frames_in_flight();
        std.debug.assert(cfi < self.vk_sets.len);

        var arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        var writes_needed_list = try std.ArrayList(*const gf.DescriptorSetUpdateWriteInfo).initCapacity(alloc, 32);
        defer writes_needed_list.deinit(alloc);

        var more_updates_to_come = false;
        var writes_iter = self.write_infos.valueIterator();
        while (writes_iter.next()) |write| {
            if (!more_updates_to_come and write.updated_sets.count() < fif) {
                more_updates_to_come = true;
            }
            if (!write.updated_sets.isSet(cfi)) {
                try writes_needed_list.append(alloc, &write.write);
                write.updated_sets.set(cfi);
            }
        }

        if (!more_updates_to_come) {
            std.debug.assert(writes_needed_list.items.len == 0);
            self.completed_update_propogations = true;
            return;
        }

        const vk_write_infos = try arena.alloc(c.VkWriteDescriptorSet, writes_needed_list.items.len);
        defer arena.free(vk_write_infos);

        for (writes_needed_list.items, 0..) |write, idx| {
            const vk_write_info = &vk_write_infos[idx];

            vk_write_info.* = c.VkWriteDescriptorSet {
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.vk_sets[cfi],
                .dstBinding = write.binding,
                .dstArrayElement = write.array_element,
                .descriptorCount = undefined,
                .descriptorType = vk.bindingtype_to_vulkan(switch (write.data) {
                    .UniformBuffer, .UniformBufferArray => .UniformBuffer,
                    .StorageBuffer, .StorageBufferArray => .StorageBuffer,
                    .ImageView, .ImageViewArray => .ImageView,
                    .Sampler, .SamplerArray => .Sampler,
                    .ImageViewAndSampler, .ImageViewAndSamplerArray => .ImageViewAndSampler,
                    .StorageImage, .StorageImageArray => .StorageImage,
                }),
                .pBufferInfo = null,
                .pImageInfo = null,
                .pTexelBufferView = null,
            };

            switch (write.data) {
                .UniformBuffer, .StorageBuffer => |bw| {
                    const buffer = try bw.buffer.get();

                    const buffer_data = try arena.create(c.VkDescriptorBufferInfo);
                    buffer_data.* = c.VkDescriptorBufferInfo {
                        .buffer = buffer.platform.get_frame_vk_buffer(), // TODO frames in flight is a pain in the ass
                        .offset = bw.offset,
                        .range = bw.range,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pBufferInfo = buffer_data;
                },
                .ImageView, .StorageImage => |iw| {
                    const view = try iw.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .sampler = null,
                        .imageView = view.platform.get_frame_view(),
                        .imageLayout = switch (write.data) {
                            .ImageView => c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                            .StorageImage => c.VK_IMAGE_LAYOUT_GENERAL,
                            else => unreachable,
                        },
                    };
                    
                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .Sampler => |sw| {
                    const sampler = try sw.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .sampler = sampler.platform.vk_sampler,
                        .imageView = null,
                        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .ImageViewAndSampler => |iw| {
                    const view = try iw.view.get();
                    const sampler = try iw.sampler.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .imageView = view.platform.get_frame_view(),
                        .sampler = sampler.platform.vk_sampler,
                        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .UniformBufferArray, .StorageBufferArray => |buffer_writes| {
                    const buffer_data_array = try arena.alloc(c.VkDescriptorBufferInfo, buffer_writes.len);

                    for (buffer_writes, 0..) |bw, bw_idx| {
                        const buffer = try bw.buffer.get();

                        buffer_data_array[bw_idx] = c.VkDescriptorBufferInfo {
                            .buffer = buffer.platform.get_frame_vk_buffer(),
                            .offset = bw.offset,
                            .range = bw.range,
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(buffer_data_array.len);
                    vk_write_info.pBufferInfo = buffer_data_array.ptr;
                },
                .ImageViewArray, .StorageImageArray => |image_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, image_writes.len);

                    for (image_writes, 0..) |iw, iw_idx| {
                        const view = try iw.get();

                        data_array[iw_idx] = c.VkDescriptorImageInfo {
                            .sampler = null,
                            .imageView = view.platform.get_frame_view(),
                            .imageLayout = switch (write.data) {
                                .ImageViewArray => c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                .StorageImageArray => c.VK_IMAGE_LAYOUT_GENERAL,
                                else => unreachable,
                            },
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
                },
                .SamplerArray => |sampler_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, sampler_writes.len);

                    for (sampler_writes, 0..) |sw, sw_idx| {
                        const sampler = try sw.get();

                        data_array[sw_idx] = c.VkDescriptorImageInfo {
                            .sampler = sampler.platform.vk_sampler,
                            .imageView = null,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
                },
                .ImageViewAndSamplerArray => |image_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, image_writes.len);

                    for (image_writes, 0..) |iw, iw_idx| {
                        const view = try iw.view.get();
                        const sampler = try iw.sampler.get();

                        data_array[iw_idx] = c.VkDescriptorImageInfo {
                            .imageView = view.platform.get_frame_view(),
                            .sampler = sampler.platform.vk_sampler,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                    }
                    
                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
                }
            }
        }

        c.vkUpdateDescriptorSets(
            GfxStateVulkan.get().device,
            @intCast(vk_write_infos.len),
            @ptrCast(vk_write_infos.ptr),
            0,
            null
        );
    }
};

const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;
const DescriptorSetVulkan = @import("vk_descriptor_set.zig").DescriptorSetVulkan;

pub const DescriptorPoolVulkan = struct {
    vk_pool: c.VkDescriptorPool,

    pub fn deinit(self: *const DescriptorPoolVulkan) void {
        c.vkDestroyDescriptorPool(GfxStateVulkan.get().device, self.vk_pool, null);
    }

    pub fn init(info: gf.DescriptorPoolInfo) !DescriptorPoolVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        const vk_pool_sizes: []c.VkDescriptorPoolSize = switch (info.strategy) {
            .Layout => |layout_ref| blk: {
                const layout = try layout_ref.get();

                var descriptor_counts: [@typeInfo(gf.BindingType).@"enum".fields.len]u32 = undefined;
                @memset(descriptor_counts[0..], 0);

                for (layout.info.bindings) |binding| {
                    descriptor_counts[@intFromEnum(binding.binding_type)] += binding.array_count;
                }

                var vk_pool_sizes_list = try std.ArrayList(c.VkDescriptorPoolSize).initCapacity(alloc, descriptor_counts.len);
                defer vk_pool_sizes_list.deinit(alloc);

                for (descriptor_counts[0..], 0..) |desc, idx| {
                    if (desc > 0) {
                        try vk_pool_sizes_list.append(alloc, c.VkDescriptorPoolSize {
                            .type = vk.bindingtype_to_vulkan(@enumFromInt(idx)),
                            .descriptorCount = desc,
                        });
                    }
                }

                vk_pool_sizes_list.shrinkAndFree(alloc, vk_pool_sizes_list.items.len);
                break :blk try vk_pool_sizes_list.toOwnedSlice(alloc);
            },
            .Manual => |pool_sizes| blk: {
                const vk_pool_sizes = try alloc.alloc(c.VkDescriptorPoolSize, pool_sizes.len);

                for (pool_sizes, 0..) |size, idx| {
                    vk_pool_sizes[idx] = c.VkDescriptorPoolSize {
                        .type = vk.bindingtype_to_vulkan(size.binding_type),
                        .descriptorCount = size.count,
                    };
                }

                break :blk vk_pool_sizes;
            },
        };
        defer alloc.free(vk_pool_sizes);

        for (vk_pool_sizes) |*pool_size| {
            // TODO check we can actually create this many in the pool
            pool_size.descriptorCount *= info.max_sets * GfxStateVulkan.get().frames_in_flight();
        }

        const pool_info = c.VkDescriptorPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = info.max_sets * GfxStateVulkan.get().frames_in_flight(),
            .pPoolSizes = @ptrCast(vk_pool_sizes.ptr),
            .poolSizeCount = @intCast(vk_pool_sizes.len),
        };

        var vk_pool: c.VkDescriptorPool = undefined;
        try vkt(c.vkCreateDescriptorPool(GfxStateVulkan.get().device, &pool_info, null, &vk_pool));
        errdefer c.vkDestroyDescriptorPool(GfxStateVulkan.get().device, vk_pool, null);

        return DescriptorPoolVulkan {
            .vk_pool = vk_pool,
        };
    }

    pub fn allocate_sets(
        self: *const DescriptorPoolVulkan,
        alloc: std.mem.Allocator,
        info: gf.DescriptorSetInfo,
        number_of_sets: u32
    ) ![]gf.DescriptorSet {
        const fif = GfxStateVulkan.get().frames_in_flight();
        const number_of_vk_sets = number_of_sets * fif;

        // todo multiple sets using multiple different layouts?
        const layout = try info.layout.get();

        const layouts = try alloc.alloc(c.VkDescriptorSetLayout, number_of_vk_sets);
        defer alloc.free(layouts);

        for (layouts) |*l| {
            l.* = layout.platform.vk_layout;
        }

        const alloc_info = c.VkDescriptorSetAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.vk_pool,
            .pSetLayouts = @ptrCast(layouts.ptr),
            .descriptorSetCount = @intCast(layouts.len),
        };

        const vk_sets = try alloc.alloc(c.VkDescriptorSet, number_of_vk_sets);
        defer alloc.free(vk_sets);

        try vkt(c.vkAllocateDescriptorSets(GfxStateVulkan.get().device, &alloc_info, @ptrCast(vk_sets.ptr)));
        errdefer {
            if (false) { // TODO free individual sets
                vkt(c.vkFreeDescriptorSets(GfxStateVulkan.get().device, self.vk_pool, @intCast(vk_sets.len), @ptrCast(vk_sets.ptr))) catch |err| {
                    std.log.err("Unable to free descriptor sets: {}", .{err});
                };
            }
        }

        const sets = try alloc.alloc(gf.DescriptorSet, number_of_sets);
        errdefer alloc.free(sets);

        var vk_sets_window_iter = std.mem.window(c.VkDescriptorSet, vk_sets, fif, fif);
        var idx: usize = 0;
        while (vk_sets_window_iter.next()) |vk_set_chunk| {
            sets[idx] = gf.DescriptorSet {
                .platform = try DescriptorSetVulkan.init(self.vk_pool, vk_set_chunk, false),
            };
            idx += 1;
        }

        if (idx != number_of_sets) {
            return error.WasntAbleToFillAllRequestedSets;
        }

        return sets;
    }
};
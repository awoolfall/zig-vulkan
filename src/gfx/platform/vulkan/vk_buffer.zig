const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

pub const BufferVulkan = struct {
    const Self = @This();

    buffer_size: u64,
    aligned_buffer_size: u64,
    vk_buffers: []c.VkBuffer,
    vk_device_memory: c.VkDeviceMemory,

    pub fn deinit(self: *const Self) void {
        // Remove this buffer from FiF buffer data propogation structure
        {
            var iter = std.mem.reverseIterator(GfxStateVulkan.get().buffer_updates.items);
            while (iter.nextPtr()) |item| {
                if (item.vk_buffers[0] == self.vk_buffers[0]) {
                    _ = GfxStateVulkan.get().buffer_updates.swapRemove(iter.index);
                }
            }
        }

        // Free vulkan memory and destroy vulkan buffers
        for (self.vk_buffers) |buf| {
            c.vkDestroyBuffer(eng.get().gfx.platform.device, buf, null);
        }
        c.vkFreeMemory(eng.get().gfx.platform.device, self.vk_device_memory, null);

        // Free cpu memory assosciated with buffer
        GfxStateVulkan.get().alloc.free(self.vk_buffers);
    }

    pub fn init(
        byte_size: u32,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
    ) !Self {
        const fif = GfxStateVulkan.get().frames_in_flight();
        const alloc = GfxStateVulkan.get().alloc;

        // @TODO: use the dedicated transfer queue
        const use_shared = false; // gfx.platform.queues.has_distinct_transfer_queue() and
            // (access_flags.CpuRead or access_flags.CpuWrite);
        const family_indices: []const u32 = &.{
            GfxStateVulkan.get().queues.all_family_index,
            GfxStateVulkan.get().queues.cpu_gpu_transfer_family_index
        };


        const buffer_is_immutable = (access_flags.CpuWrite == false and access_flags.GpuWrite == false);
        const vk_buffer_count = if (buffer_is_immutable) 1 else fif;

        var usage_flags_plus = usage_flags;
        // Allow FiF transfers
        if (vk_buffer_count == fif) {
            usage_flags_plus.TransferSrc = true;
            usage_flags_plus.TransferDst = true;
        }

        const buffer_create_info = c.VkBufferCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .sharingMode = if (use_shared) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE,
            .pQueueFamilyIndices = @ptrCast(family_indices.ptr),
            .queueFamilyIndexCount = if (use_shared) @intCast(family_indices.len) else 1,
            .size = @intCast(byte_size),
            .usage = vk.convert_buffer_usage_flags_to_vulkan(usage_flags_plus),
        };
        std.debug.assert(buffer_create_info.usage != 0);

        const vk_buffers = try alloc.alloc(c.VkBuffer, vk_buffer_count);
        errdefer alloc.free(vk_buffers);

        var vk_buffers_list = std.ArrayList(c.VkBuffer).initBuffer(vk_buffers);
        errdefer for (vk_buffers_list.items) |b| { c.vkDestroyBuffer(GfxStateVulkan.get().device, b, null); };

        for (0..vk_buffer_count) |_| {
            var vk_buffer: c.VkBuffer = undefined;
            try vkt(c.vkCreateBuffer(GfxStateVulkan.get().device, &buffer_create_info, null, &vk_buffer));
            errdefer c.vkDestroyBuffer(GfxStateVulkan.get().device, vk_buffer, null);

            try vk_buffers_list.append(alloc, vk_buffer);
        }

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(GfxStateVulkan.get().device, vk_buffers_list.items[0], &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = if (access_flags.CpuRead or access_flags.CpuWrite)
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            else c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const vk_limits = GfxStateVulkan.get().physical_device_properties.limits;

        var lcm_alignment: u64 = 1;
        if (access_flags.CpuRead or access_flags.CpuWrite) {
            lcm_alignment = vk.lcm(lcm_alignment, vk_limits.minMemoryMapAlignment);
        }
        if (usage_flags_plus.ConstantBuffer) {
            lcm_alignment = vk.lcm(lcm_alignment, vk_limits.minUniformBufferOffsetAlignment);
        }
        // TODO check if this will explode alignment value or not
        // if (usage_flags_plus.TransferSrc or usage_flags_plus.TransferDst) {
        //     lcm_alignment = lcm(lcm_alignment, vk_limits.optimalBufferCopyOffsetAlignment);
        // }
        const vk_buffer_size_aligned = vk.align_up(vk_memory_requirements.size, lcm_alignment);

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_buffer_size_aligned * vk_buffer_count,
            .memoryTypeIndex = try vk.find_vulkan_memory_type(
                vk_memory_requirements.memoryTypeBits,
                memory_properties,
            ),
        };

        // TODO better memory allocation strategy
        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

        for (vk_buffers_list.items, 0..) |vk_buffer, idx| {
            try vkt(c.vkBindBufferMemory(GfxStateVulkan.get().device, vk_buffer, vk_device_memory, idx * vk_buffer_size_aligned));
        }

        return .{
            .buffer_size = @intCast(byte_size),
            .aligned_buffer_size = @intCast(vk_buffer_size_aligned),
            .vk_buffers = vk_buffers,
            .vk_device_memory = vk_device_memory,
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
    ) !Self {
        var usage_flags_plus = usage_flags;
        usage_flags_plus.TransferDst = true;

        const self = try Self.init(@intCast(data.len), usage_flags_plus, access_flags);
        errdefer self.deinit();

        const staging = try Self.init_staging(data.len);
        defer staging.deinit();

        {
            var data_ptr: ?*anyopaque = undefined;
            try vkt(c.vkMapMemory(GfxStateVulkan.get().device, staging.vk_device_memory, 0, staging.buffer_size, 0, &data_ptr));
            defer c.vkUnmapMemory(GfxStateVulkan.get().device, staging.vk_device_memory);

            @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..(data.len)], data[0..]);
        }

        var command_buffer = try vk.begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);

        for (self.vk_buffers) |vk_buffer| {
            const buffer_copy_region = c.VkBufferCopy {
                .size = data.len,
                .dstOffset = 0,
                .srcOffset = 0,
            };
            c.vkCmdCopyBuffer(command_buffer.platform.vk_command_buffer, staging.get_frame_vk_buffer(), vk_buffer, 1, &buffer_copy_region);
        }

        vk.end_single_time_command_buffer(&command_buffer, null);

        return self;
    }

    pub fn init_staging(
        byte_size: usize,
    ) !Self {
        const alloc = GfxStateVulkan.get().alloc;

        // @TODO: use the dedicated transfer queue
        const use_shared = false; // gfx.platform.queues.has_distinct_transfer_queue() and
            // (access_flags.CpuRead or access_flags.CpuWrite);
        const family_indices: []const u32 = &.{
            GfxStateVulkan.get().queues.all_family_index,
            GfxStateVulkan.get().queues.cpu_gpu_transfer_family_index
        };

        const buffer_create_info = c.VkBufferCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .sharingMode = if (use_shared) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE,
            .pQueueFamilyIndices = @ptrCast(family_indices.ptr),
            .queueFamilyIndexCount = if (use_shared) @intCast(family_indices.len) else 1,
            .size = @intCast(byte_size),
            .usage = vk.convert_buffer_usage_flags_to_vulkan(.{ .TransferSrc = true, }),
        };
        std.debug.assert(buffer_create_info.usage != 0);

        var vk_buffer: c.VkBuffer = undefined;
        try vkt(c.vkCreateBuffer(GfxStateVulkan.get().device, &buffer_create_info, null, &vk_buffer));
        errdefer c.vkDestroyBuffer(GfxStateVulkan.get().device, vk_buffer, null);

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(GfxStateVulkan.get().device, vk_buffer, &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = 
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        const vk_limits = GfxStateVulkan.get().physical_device_properties.limits;

        var lcm_alignment: u64 = 1;
        lcm_alignment = vk.lcm(lcm_alignment, vk_limits.minMemoryMapAlignment);
        lcm_alignment = vk.lcm(lcm_alignment, vk_limits.optimalBufferCopyOffsetAlignment);
        const vk_buffer_size_aligned = vk.align_up(vk_memory_requirements.size, lcm_alignment);

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_buffer_size_aligned,
            .memoryTypeIndex = try vk.find_vulkan_memory_type(
                vk_memory_requirements.memoryTypeBits,
                memory_properties,
            ),
        };

        // TODO better memory allocation strategy
        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

        try vkt(c.vkBindBufferMemory(GfxStateVulkan.get().device, vk_buffer, vk_device_memory, 0));

        const vk_buffers = try alloc.alloc(c.VkBuffer, 1);
        errdefer alloc.free(vk_buffers);

        vk_buffers[0] = vk_buffer;

        return .{
            .buffer_size = @intCast(byte_size),
            .aligned_buffer_size = @intCast(vk_buffer_size_aligned),
            .vk_buffers = vk_buffers,
            .vk_device_memory = vk_device_memory,
        };
    }

    pub fn map(self: *const Self, options: gf.Buffer.MapOptions) !MappedBuffer {
        const cfi = GfxStateVulkan.get().current_frame_index();
        const buffer_index = cfi % self.vk_buffers.len;

        var data_ptr: ?*anyopaque = undefined;
        try vkt(c.vkMapMemory(
                GfxStateVulkan.get().device,
                self.vk_device_memory,
                @as(u64, @intCast(buffer_index)) * self.aligned_buffer_size,
                self.buffer_size,
                0,
                &data_ptr
        ));

        if (options.write == .Infrequent and self.vk_buffers.len > 1) {
            for (GfxStateVulkan.get().buffer_updates.items) |*item| {
                if (item.vk_buffers[0] == self.vk_buffers[0]) {
                    item.count = 0;
                    break;
                }
            } else {
                try GfxStateVulkan.get().buffer_updates.append(GfxStateVulkan.get().alloc, GfxStateVulkan.BufferUpdates {
                    .vk_buffers = self.vk_buffers,
                    .size = self.buffer_size,
                    .count = 0,
                });
            }
        }

        return MappedBuffer {
            .data_ptr = data_ptr,
            .device_memory = self.vk_device_memory,
        };
    }

    pub const MappedBuffer = struct {
        data_ptr: ?*anyopaque,
        device_memory: c.VkDeviceMemory,

        pub inline fn unmap(self: *const MappedBuffer) void {
            c.vkUnmapMemory(GfxStateVulkan.get().device, self.device_memory);
        }

        pub inline fn data(self: *const MappedBuffer, comptime Type: type) *Type {
            return @alignCast(@ptrCast(self.data_ptr));
        }

        pub inline fn data_array(self: *const MappedBuffer, comptime Type: type, length: usize) []Type {
            return @as([*]Type, @alignCast(@ptrCast(self.data_ptr)))[0..(length)];
        }
    };

    pub fn get_frame_vk_buffer(self: *const BufferVulkan) c.VkBuffer {
        const cfi = GfxStateVulkan.get().current_frame_index();
        return self.vk_buffers[@as(usize, @intCast(cfi)) % self.vk_buffers.len];
    }
};
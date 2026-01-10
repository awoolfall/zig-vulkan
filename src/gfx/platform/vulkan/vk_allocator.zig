const std = @import("std");
const c = @import("../vulkan_import.zig").c;

pub const VkAllocator = struct {
    const UserData = struct {
        alloc: std.mem.Allocator,
    };

    user_data: *UserData,

    pub fn deinit(self: *VkAllocator) void {
        const alloc = self.user_data.alloc;
        alloc.destroy(self.user_data);
    }

    pub fn init(alloc: std.mem.Allocator) !VkAllocator {
        const user_data = try alloc.create(VkAllocator.UserData);
        errdefer alloc.destroy(user_data);

        user_data.* = UserData {
            .alloc = alloc,
        };

        return VkAllocator {
            .user_data = user_data,
        };
    }

    pub fn vk_callbacks(self: *const VkAllocator) c.VkAllocationCallbacks {
        return c.VkAllocationCallbacks {
            .pUserData = @ptrCast(self.user_data),
            .pfnAllocation = VkAllocator.alloc_fn,
            .pfnReallocation = VkAllocator.realloc_fn,
            .pfnFree = VkAllocator.free_fn,
            .pfnInternalAllocation = VkAllocator.internal_alloc_notif_fn,
            .pfnInternalFree = VkAllocator.internal_free_notif_fn,
        };
    }

    fn cast_user_data(ptr: ?*anyopaque) ?*UserData {
        return @ptrCast(ptr);
    }

    pub fn alloc_fn(pUserData: ?*anyopaque, size: usize, alignment: usize, allocationScope: c.VkSystemAllocationScope) callconv(.c) ?*anyopaque {
        _ = allocationScope;

        const user_data = cast_user_data(pUserData) orelse return null;
        if (!std.math.isPowerOfTwo(alignment)) { return null; }

        const allocation = user_data.alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alignment), size) catch |err| {
            std.log.err("VkAllocator: Unable to allocate memory: {}", .{err});
            return null;
        };
        return @ptrCast(allocation.ptr);
    }

    pub fn realloc_fn(pUserData: ?*anyopaque, pOriginal: ?*anyopaque, size: usize, alignment: usize, allocationScope: c.VkSystemAllocationScope) callconv(.c) ?*anyopaque {
        const user_data = cast_user_data(pUserData) orelse return null;
        if (!std.math.isPowerOfTwo(alignment)) { return null; }

        if (pOriginal == null) {
            return alloc_fn(pUserData, size, alignment, allocationScope);
        } else {
            const new_allocation = user_data.alloc.realloc(@as([*]u8, @ptrCast(pOriginal.?)), size) catch |err| {
                std.log.err("VkAllocator: Unable to reallocate memory: {}", .{err});
                return null;
            };
            return @ptrCast(new_allocation.ptr);
        }
    }

    pub fn free_fn(pUserData: ?*anyopaque, pMemory: ?*anyopaque) callconv(.c) void {
        const user_data = cast_user_data(pUserData) orelse return;
        if (pMemory == null) { return; }
        user_data.alloc.free(@as([*]u8, @ptrCast(pMemory.?)));
    }

    pub fn internal_alloc_notif_fn(pUserData: ?*anyopaque, size: usize, allocationType: c.VkInternalAllocationType, allocationScope: c.VkSystemAllocationScope) callconv(.c) void {
        _ = pUserData;
        _ = size;
        _ = allocationType;
        _ = allocationScope;
    }

    pub fn internal_free_notif_fn(pUserData: ?*anyopaque, size: usize, allocationType: c.VkInternalAllocationType, allocationScope: c.VkSystemAllocationScope) callconv(.c) void {
        _ = pUserData;
        _ = size;
        _ = allocationType;
        _ = allocationScope;
    }
};

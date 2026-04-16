const std = @import("std");
const eng = @import("self");
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;

pub const AllocationHandle = struct {
    memory_group_id: u32,
    binary_path: BTree.Path,
    allocation_size: u32,
};

// Vk device memory allocator using a 'Buddy' Memory Allocation scheme
pub const VkDeviceMemoryAllocator = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    vk_device: c.VkDevice,
    memory_groups: std.ArrayList(MemoryGroup),

    pub fn deinit(self: *Self) void {
        if (self.memory_groups.items.len > 0) {
            std.log.warn("Not all memory groups have been cleared", .{});
        }
        for (self.memory_groups.items) |*group| {
            group.deinit();
        }
        self.memory_groups.deinit(self.alloc);
    }

    pub fn init(alloc: std.mem.Allocator, vk_device: c.VkDevice) !VkDeviceMemoryAllocator {
        const memory_groups = try std.ArrayList(MemoryGroup).initCapacity(alloc, 8);
        errdefer memory_groups.deinit(alloc);

        return VkDeviceMemoryAllocator {
            .alloc = alloc,
            .vk_device = vk_device,
            .memory_groups = memory_groups,
        };
    }

    pub fn allocate(self: *VkDeviceMemoryAllocator, allocation_size: u32, memory_type_index: u32) !AllocationHandle {
        if (allocation_size == 0) { return error.AllocationSizeMustNotBeZero; }

        for (self.memory_groups.items, 0..) |*group, group_idx| {
            if (group.vk_memory_type_index == memory_type_index) {
                const allocation_path = group.allocate(allocation_size) catch { continue; };
                return AllocationHandle {
                    .memory_group_id = group_idx,
                    .binary_path = allocation_path,
                    .allocation_size = allocation_size,
                };
            }
        }
        
        const memory_group_size = std.math.pow(2, 24);
        std.debug.assert(allocation_size < memory_group_size);

        const new_memory_group = try MemoryGroup.init(memory_group_size, memory_type_index);
        errdefer new_memory_group.deinit();

        const path = try new_memory_group.allocate(allocation_size);

        try self.memory_groups.append(eng.get().general_allocator, new_memory_group);

        return AllocationHandle {
            .memory_group_id = self.memory_groups.items.len - 1,
            .binary_path = path,
            .allocation_size = allocation_size,
        };
    }

    pub fn deallocate(self: *VkDeviceMemoryAllocator, allocation: AllocationHandle) !void {
        if (allocation.memory_group_id >= self.memory_groups.items.len) { error.MemoryGroupIdxDoesNotExist; }
        try self.memory_groups.items[allocation.memory_group_id].deallocate(allocation);
    }
};

const BTree = struct {
    pub const Path = packed struct (u32) {
        const max_len = 24;
        path: u24,
        len: u8,

        pub inline fn bit_is_set(self: Path, bit: anytype) bool {
            return (self.path & (@as(u24, 1) << @intCast(bit))) != 0;
        }
    };

    pub const Node = struct {
        pub const Direction = enum (u1) { Left = 0, Right = 1 };

        left: ?*Node = null,
        right: ?*Node = null,

        allocation: ?u32 = null,

        pub fn deinit(self: *BTree.Node, alloc: std.mem.Allocator) void {
            //std.debug.assert(self.allocation == null);
            self.destroy_child(alloc, .Left);
            self.destroy_child(alloc, .Right);
        }

        pub fn create_child(self: *BTree.Node, alloc: std.mem.Allocator, dir: Direction) !void {
            if ((if (dir == .Left) self.left else self.right) != null) { return error.NodeIsNotNull; }
            const new_node = try alloc.create(BTree.Node);
            new_node.* = .{};
            (if (dir == .Left) self.left else self.right) = new_node;
        }

        pub fn destroy_child(self: *BTree.Node, alloc: std.mem.Allocator, dir: Direction) void {
            if (if (dir == .Left) self.left else self.right) |node| {
                node.deinit(alloc);
                alloc.destroy(node);
            }
            (if (dir == .Left) self.left else self.right) = null;
        }
    };

    alloc: std.mem.Allocator,
    root_node: Node,

    pub fn deinit(self: *BTree) void {
        self.root_node.deinit(self.alloc);
    }

    pub fn init(alloc: std.mem.Allocator) !BTree {
        return BTree{
            .alloc = alloc,
            .root_node = .{},
        };
    }

    pub fn navigate_to_path(self: *BTree, path: BTree.Path) !*BTree.Node {
        var node: *BTree.Node = &self.root_node;
        for (0..path.len) |bit| {
            if (if (path.bit_is_set(bit)) node.right else node.left) |next_node| {
                node = next_node;
            } else {
                return error.NodeAtPathDoesNotExist;
            }
        }
        return node;
    }

    pub fn find_branch_root(self: *BTree, leaf_path: BTree.Path) !struct { *BTree.Node, BTree.Node.Direction } {
        var branch_root_node = &self.root_node;
        var branch_direction: BTree.Node.Direction = .Left;

        var node: *BTree.Node = &self.root_node;
        for (0..leaf_path.len) |bit| {
            const navigate_node, const branch_test_node, const navigate_direction: BTree.Node.Direction = if (leaf_path.bit_is_set(bit)) .{node.right, node.left, .Right} else .{node.left, node.right, .Left};
            
            if (branch_test_node) |_| {
                branch_root_node = node;
                branch_direction = navigate_direction;
            }

            if (navigate_node) |next_node| {
                node = next_node;
            } else {
                return error.NodeAtPathDoesNotExist;
            }
        }

        return .{ branch_root_node, branch_direction };
    }

    pub fn create_node_at_path(self: *BTree, path: BTree.Path) !*BTree.Node {
        // if creating a node fails somewhere in the chain we want to return the b-tree to the state it was previously.
        // store the 'root' of the new branch and deinit this if a error occurs.
        var new_node_root: ?struct { *BTree.Node, BTree.Node.Direction } = null;
        errdefer if (new_node_root) |pair| { pair.@"0".destroy_child(self.alloc, pair.@"1"); };

        // handle path.len == 0 case by checking if an allocation exists in the root node
        if (self.root_node.allocation != null) { return error.AllocationBlocksPath; }

        var node: *BTree.Node = &self.root_node;
        for (0..path.len) |bit| {
            if (node.allocation != null) { return error.AllocationBlocksPath; }

            if (if (path.bit_is_set(bit)) node.right else node.left) |next_node| {
                node = next_node;
            } else {
                const new_node = try self.alloc.create(BTree.Node);
                new_node.* = .{};

                (if (path.bit_is_set(bit)) node.right else node.left) = new_node;
                if (new_node_root == null) { new_node_root = .{ node, if (path.bit_is_set(bit)) .Right else .Left }; }
                node = new_node;
            }
        }
        return node;
    }
};

test BTree {
    const alloc = std.heap.page_allocator;
    
    var btree = try BTree.init(alloc);
    defer btree.deinit();
    
    try std.testing.expect(btree.root_node.allocation == null);
    try std.testing.expect(btree.root_node.left == null);
    try std.testing.expect(btree.root_node.right == null);

    // test create at root node
    _ = try btree.create_node_at_path(.{ .path = 0b0, .len = 0 });
    btree.root_node.allocation = 1;
    try std.testing.expectError(error.AllocationBlocksPath, btree.create_node_at_path(.{ .path = 0, .len = 0, }));
    btree.root_node.allocation = null;

    {
        const node_a = try btree.create_node_at_path(.{ .path = 0b000, .len = 3, });
        const node_b = try btree.create_node_at_path(.{ .path = 0b010, .len = 3, });
        try std.testing.expectEqual(node_a, try btree.navigate_to_path(.{ .path = 0b000, .len = 3, }));
        try std.testing.expectEqual(node_b, try btree.navigate_to_path(.{ .path = 0b010, .len = 3, }));
        const branch_parent_node = try btree.navigate_to_path(.{ .path = 0b0, .len = 1, });
        {
            const branch_root_pair = try btree.find_branch_root(.{ .path = 0b000, .len = 3, });
            try std.testing.expectEqual(branch_parent_node, branch_root_pair.@"0");
            try std.testing.expectEqual(BTree.Node.Direction.Left, branch_root_pair.@"1");
        }
        {
            const branch_root_pair = try btree.find_branch_root(.{ .path = 0b010, .len = 3, });
            try std.testing.expectEqual(branch_parent_node, branch_root_pair.@"0");
            try std.testing.expectEqual(BTree.Node.Direction.Right, branch_root_pair.@"1");
        }
    }
}

pub const MemoryGroup = struct {
    vk_device_memory: c.VkDeviceMemory,
    vk_memory_type_index: u32,
    memory_group_size: u32,
    b_tree: BTree,

    pub fn deinit(self: *MemoryGroup, vk_device: c.VkDevice) void {
        self.b_tree.deinit();
        c.vkFreeMemory(vk_device, self.vk_device_memory, null);
    }

    pub fn init(vk_device: c.VkDevice, memory_group_size: u32, memory_type_index: u32) !MemoryGroup {
        if (!std.math.isPowerOfTwo(memory_group_size)) { return error.MemoryGroupSizeMustBePowerOfTwo; }

        const b_tree = try BTree.init();
        errdefer b_tree.deinit();

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memory_group_size,
            .memoryTypeIndex = memory_type_index,
        };

        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(vk_device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(vk_device, vk_device_memory, null);

        return MemoryGroup {
            .vk_device_memory = vk_device_memory,
            .vk_memory_type_index = memory_type_index,
            .memory_group_size = memory_group_size,
            .b_tree = b_tree,
        };
    }

    fn find_allocation_level(self: *const MemoryGroup, allocation_size: u32) u32 {
        std.debug.assert(allocation_size <= self.memory_group_size);
        const al: u32 = @intFromFloat(@floor(std.math.log2(@as(f32, @floatFromInt(allocation_size)))));
        const ml = std.math.log2(self.memory_group_size);
        return @min(ml - al, BTree.Path.max_len);
    }

    pub fn allocate(self: *MemoryGroup, allocation_size: u32) !BTree.Path {
        if (allocation_size > self.memory_group_size) {
            return error.MemoryGroupIsFull;
        }

        // find free node
        const level = try self.find_allocation_level(allocation_size);

        for (0..std.math.pow(2, level)) |i| {
            const path = BTree.Path{ .path = @intCast(i), .len = level, };
            const node = self.b_tree.create_node_at_path(path) catch |err| {
                if (err == error.AllocationBlocksPath) { continue; }
                else { return err; }
            };
            node.allocation = allocation_size;
            return path;
        }
        return error.MemoryGroupIsFull;
    }

    pub fn deallocate(self: *MemoryGroup, allocation: AllocationHandle) !void {
        if (allocation.binary_path.len == 0) {
            if (self.b_tree.root_node.allocation == null) { error.NoAllocationExistsAtNode; }
            self.b_tree.root_node.allocation = null;
        } else {
            const node = try self.b_tree.navigate_to_path(allocation.binary_path);
            if (node.allocation == null) { error.NoAllocationExistsAtNode; }

            const branch_root_node, const branch_direction = try self.b_tree.find_branch_root(allocation.binary_path);
            branch_root_node.destroy_child(self.b_tree.alloc, branch_direction);
        }
    }
};

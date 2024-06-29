const std = @import("std");

pub const GenerationalIndex = struct {
    index: usize,
    generation: u16,
};

pub fn GenerationalList(comptime T: type) type {
    return struct {
        const Self = @This();
        const ItemType = struct {
            item_data: ?T = null,
            generation: u16 = 0,
        };

        allocator: std.mem.Allocator,
        data: std.ArrayList(ItemType),
        free_list: std.ArrayList(usize),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self {
                .allocator = allocator,
                .data = std.ArrayList(ItemType).init(allocator),
                .free_list = std.ArrayList(usize).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
            self.free_list.deinit();
        }

        fn find_free(self: *Self) ?usize {
            return self.free_list.popOrNull();
        }

        pub fn insert(self: *Self, elem: T) !GenerationalIndex {
            // find a free index to put item into
            var free_idx = self.find_free();
            // if there are no free index's, then append to list
            if (free_idx == null) {
                try self.data.append(ItemType {});
                free_idx = self.data.items.len - 1;
            }

            // insert item into free index
            self.data.items[free_idx.?].item_data = elem;
            // increment generation so that old references are invalidated
            self.data.items[free_idx.?].generation += 1;

            return GenerationalIndex {
                .index = free_idx.?,
                .generation = self.data.items[free_idx.?].generation,
            };
        }

        pub fn remove(self: *Self, idx: GenerationalIndex) !void {
            if (idx.index >= self.data.items.len) {
                return error.OutOfBoundsIndex;
            }
            const item: *ItemType = &self.data.items[idx.index];
            if (item.item_data == null) {
                return error.ItemIsAlreadyNull;
            }
            if (item.generation != idx.generation) {
                return error.InvalidGeneration;
            }

            // set data to null indicating item is removed
            item.item_data = null;
            // add index to free list to be reused later
            try self.free_list.append(idx.index);
        }

        pub fn get(self: *const Self, idx: GenerationalIndex) !*T {
            if (idx.index >= self.data.items.len) {
                return error.OutOfBoundsIndex;
            }
            const item: *ItemType = &self.data.items[idx.index];
            if (item.item_data == null) {
                return error.ItemIsNull;
            }
            if (item.generation != idx.generation) {
                return error.InvalidGeneration;
            }
            return &(item.item_data.?);
        }

        pub fn item_count(self: *const Self) usize {
            return self.data.items.len - self.free_list.items.len;
        }

        pub fn is_empty(self: *const Self) bool {
            return self.item_count() == 0;
        }
    };
}

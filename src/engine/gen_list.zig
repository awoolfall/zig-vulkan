const std = @import("std");

pub const GenerationalIndex = struct {
    index: usize,
    generation: u16,

    pub fn eql(self: GenerationalIndex, other: GenerationalIndex) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    pub fn invalid() GenerationalIndex {
        return GenerationalIndex { .index = 0, .generation = 0 };
    }

    pub fn is_invalid(self: GenerationalIndex) bool {
        return self.index == 0 and self.generation == 0;
    }
};

/// An expanding list allowing lookup by both index and generation.
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

        /// Finds a free index in the list.
        fn find_free(self: *Self) ?usize {
            return self.free_list.pop();
        }

        /// Inserts an item into the list returning a handle to the item.
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

        /// Removes an item from the list provided the supplied handle is valid.
        pub fn remove(self: *Self, idx: GenerationalIndex) !void {
            if (idx.is_invalid()) { return error.InvalidIndex; }
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

        /// Gets an item from the list by handle.
        pub fn get(self: *const Self, idx: GenerationalIndex) ?*T {
            if (idx.is_invalid()) { return null; }
            if (idx.index >= self.data.items.len) {
                return null;
            }
            const item: *ItemType = &self.data.items[idx.index];
            if (item.item_data == null) {
                return null;
            }
            if (item.generation != idx.generation) {
                return null;
            }
            return &(item.item_data.?);
        }

        /// Gets the number of valid items in the list.
        pub fn item_count(self: *const Self) usize {
            return self.data.items.len - self.free_list.items.len;
        }

        /// returns true if there are no valid items in the list.
        pub fn is_empty(self: *const Self) bool {
            return self.item_count() == 0;
        }

        pub fn iterator(self: *Self) GenerationalListIterator(T) {
            return GenerationalListIterator(T).init(self);
        }
    };
}

pub fn GenerationalListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        list: *GenerationalList(T),
        index: usize,

        pub fn init(list: *GenerationalList(T)) Self {
            return Self {
                .list = list,
                .index = 0,
            };
        }

        pub inline fn reset(self: *Self) void {
            self.* = Self.init(self.list);
        }

        pub fn next(self: *Self) ?*T {
            while (self.index < self.list.data.items.len) {
                defer self.index += 1;
                if (self.list.data.items[self.index].item_data != null) {
                    return &(self.list.data.items[self.index].item_data.?);
                }
            }
            return null;
        }
    };
}

test "GenerationalList append" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = try GenerationalList(i32).init(allocator);
    defer list.deinit();

    const one = try list.insert(1);
    const two = try list.insert(2);
    const three = try list.insert(3);

    try testing.expectEqual(3, list.item_count());
    try testing.expectEqual(0, list.free_list.items.len);

    try testing.expectEqual(1, list.get(one).?.*);
    try testing.expectEqual(2, list.get(two).?.*);
    try testing.expectEqual(3, list.get(three).?.*);
}

test "GenerationalList remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = try GenerationalList(i32).init(allocator);
    defer list.deinit();

    const one = try list.insert(1);
    const two = try list.insert(2);
    const three = try list.insert(3);

    // test remove and appending to free list
    try list.remove(one);

    try testing.expectEqual(2, list.item_count());
    try testing.expectEqual(1, list.free_list.items.len);

    try testing.expectEqual(2, list.get(two).?.*);
    try testing.expectEqual(3, list.get(three).?.*);
}

test "GenerationalList generations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = try GenerationalList(i32).init(allocator);
    defer list.deinit();

    const one = try list.insert(1);
    const two = try list.insert(2);
    const three = try list.insert(3);

    // test generations
    try list.remove(one);
    const one_gen_1 = try list.insert(11);

    try testing.expectEqual(0, list.free_list.items.len);
    try testing.expectEqual(3, list.data.items.len);

    try testing.expectEqual(2, one_gen_1.generation);

    try testing.expectEqual(null, list.get(one));
    try testing.expectEqual(11, list.get(one_gen_1).?.*);

    try testing.expectEqual(2, list.get(two).?.*);
    try testing.expectEqual(3, list.get(three).?.*);
}

test "GenerationalList remove with invalid generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = try GenerationalList(i32).init(allocator);
    defer list.deinit();

    const one = try list.insert(1);
    const two = try list.insert(2);
    const three = try list.insert(3);
    
    try list.remove(one);
    const one_gen_1 = try list.insert(11);

    // test remove with invalid generation
    try testing.expectError(error.InvalidGeneration, list.remove(one));
    try list.remove(one_gen_1);

    try testing.expectEqual(2, list.item_count());
    try testing.expectEqual(1, list.free_list.items.len);

    try list.remove(two);

    try testing.expectEqual(1, list.item_count());
    try testing.expectEqual(2, list.free_list.items.len);

    try testing.expectEqual(3, list.get(three).?.*);

    try list.remove(three);

    try testing.expectEqual(0, list.item_count());
}

test "GenerationalList out of bounds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = try GenerationalList(i32).init(allocator);
    defer list.deinit();

    const one = try list.insert(1);
    const two = try list.insert(2);
    const three = try list.insert(3);
    try list.remove(one);
    try list.remove(two);
    try list.remove(three);

    // test out of bounds
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 0, .generation = 0 }));
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 1, .generation = 0 }));
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 0, .generation = 1 }));
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 1, .generation = 1 }));
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 10000, .generation = 1 }));
    try testing.expectEqual(null, list.get(GenerationalIndex { .index = 0, .generation = 10000 }));
}

const std = @import("std");

pub const GenerationalIndex = struct {
    index: usize,
    generation: u16,
};

pub fn GenerationalList(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        data: std.ArrayList(?T),
        generations: std.ArrayList(u16),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self {
                .allocator = allocator,
                .data = std.ArrayList(?T).init(allocator),
                .generations = std.ArrayList(u16).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
            self.generations.deinit();
        }

        fn find_free(self: *Self) ?usize {
            for (self.data.items, 0..) |d, idx| {
                if (d == null) {
                    return idx;
                }
            }
            return null;
        }

        pub fn insert(self: *Self, elem: T) !GenerationalIndex {
            var free_idx = self.find_free();
            if (free_idx == null) {
                try self.data.append(null);
                try self.generations.append(0);
                free_idx = self.data.items.len - 1;
            }
            self.data.items[free_idx.?] = elem;
            self.generations.items[free_idx.?] = self.generations.items[free_idx.?] + 1;
            std.debug.assert(self.data.items.len == self.generations.items.len);
            return GenerationalIndex {
                .index = free_idx.?,
                .generation = self.generations.items[free_idx.?],
            };
        }

        pub fn remove(self: *Self, idx: GenerationalIndex) !void {
            if (idx.index >= self.data.items.len) {
                return error.OutOfBoundsIndex;
            }
            if (self.data.items[idx.index] == null) {
                return error.ItemIsAlreadyNull;
            }
            if (self.generations.items[idx.index] != idx.generation) {
                return error.InvalidGeneration;
            }
            self.data.items[idx.index] = null;
        }

        pub fn get(self: *Self, idx: GenerationalIndex) !*T {
            if (idx.index >= self.data.items.len) {
                return error.OutOfBoundsIndex;
            }
            if (self.data.items[idx.index] == null) {
                return error.ItemIsNull;
            }
            if (self.generations.items[idx.index] != idx.generation) {
                return error.InvalidGeneration;
            }
            return &(self.data.items[idx.index].?);
        }
    };
}

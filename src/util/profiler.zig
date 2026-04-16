const Self = @This();

const std = @import("std");

const ProfiledContext = struct {
    name: []const u8,
    start_time: std.time.Instant,
    end_time: ?std.time.Instant = null,
};

alloc: std.mem.Allocator,
contexts_map: std.AutoHashMap(u64, ProfiledContext),

pub fn deinit(self: *Self) void {
    self.end_frame();
    self.contexts_map.deinit();
}

pub fn init(alloc: std.mem.Allocator) Self {
    const contexts_map = std.AutoHashMap(u64, ProfiledContext).init(alloc);
    errdefer contexts_map.deinit();

    return .{
        .alloc = alloc,
        .contexts_map = contexts_map,
    };
}

pub fn end_frame(self: *Self) void {
    var contexts_map_iterator = self.contexts_map.valueIterator();
    while (contexts_map_iterator.next()) |context| {
        self.alloc.free(context.name);
    }
    self.contexts_map.clearRetainingCapacity();
}

fn hash_context_name(name: []const u8) u64 {
    return std.hash_map.hashString(name);
}

pub const ProfileContext = struct {
    profiler: *Self,
    identifier: u64,

    pub fn end_context(self: *const ProfileContext) void {
        self.profiler.end_context(self);
    }
};

pub fn start_context(self: *Self, name: []const u8) ProfileContext {
    const name_hash = hash_context_name(name);
    std.debug.assert(!self.contexts_map.contains(name_hash));

    const name_owned = self.alloc.dupe(u8, name) catch unreachable;
    errdefer self.alloc.free(name_owned);

    const hashmap_entry = self.contexts_map.getOrPut(name_hash) catch unreachable;

    hashmap_entry.value_ptr.* = .{
        .name = name_owned,
        .start_time = std.time.Instant.now() catch unreachable,
    };

    return ProfileContext {
        .profiler = self,
        .identifier = name_hash,
    };
}

pub fn end_context(self: *Self, context: *const ProfileContext) void {
    const hashmap_entry = self.contexts_map.getPtr(context.identifier) orelse return;
    hashmap_entry.end_time = std.time.Instant.now() catch unreachable;
}

const Self = @This();

const std = @import("std");

const ProfiledContext = struct {
    name_hash: u64,
    result_duration_ns: u64 = 0,

    pub fn result_duration_ms(self: *const ProfiledContext) f32 {
        return @floatCast(@as(f64, @floatFromInt(self.result_duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)));
    }
};

alloc: std.mem.Allocator,
contexts_array: std.ArrayList(ProfiledContext),
context_names_map: std.AutoHashMap(u64, []const u8),

pub fn deinit(self: *Self) void {
    self.end_frame();
    self.context_names_map.deinit();
    self.contexts_array.deinit(self.alloc);
}

pub fn init(alloc: std.mem.Allocator) Self {
    const context_names_map = std.AutoHashMap(u64, []const u8).init(alloc);
    errdefer context_names_map.deinit();

    return .{
        .alloc = alloc,
        .contexts_array = .empty,
        .context_names_map = context_names_map,
    };
}

pub fn end_frame(self: *Self) void {
    var names_map_iterator = self.context_names_map.valueIterator();
    while (names_map_iterator.next()) |name| {
        self.alloc.free(name.*);
    }
    self.context_names_map.clearRetainingCapacity();
    self.contexts_array.clearRetainingCapacity();
}

fn hash_context_name(name: []const u8) u64 {
    return std.hash_map.hashString(name);
}

pub const ProfileContext = struct {
    profiler: *Self,
    index: usize,
    start_time: std.time.Instant,

    pub fn end_context(self: *const ProfileContext) void {
        self.profiler.end_context(self);
    }
};

pub fn start_context(self: *Self, name: []const u8) ProfileContext {
    const name_hash = hash_context_name(name);

    if (!self.context_names_map.contains(name_hash)) {
        const name_owned = self.alloc.dupe(u8, name) catch unreachable;
        errdefer self.alloc.free(name_owned);

        const hashmap_entry = self.context_names_map.getOrPut(name_hash) catch unreachable;

        hashmap_entry.value_ptr.* = name_owned;
    }

    const index = self.contexts_array.items.len;
    self.contexts_array.append(self.alloc, .{
        .name_hash = name_hash,
    }) catch unreachable;

    return ProfileContext {
        .profiler = self,
        .index = index,
        .start_time = std.time.Instant.now() catch unreachable,
    };
}

pub fn end_context(self: *Self, context: *const ProfileContext) void {
    const end_time = std.time.Instant.now() catch unreachable;
    const duration = end_time.since(context.start_time);
    self.contexts_array.items[context.index].result_duration_ns = duration;
}

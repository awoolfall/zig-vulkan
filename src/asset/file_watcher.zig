const Self = @This();

const std = @import("std");

arena: std.heap.ArenaAllocator,
dir: []const u8,
filename: []const u8,
last_modified: i128,
last_check_time: std.time.Instant,
check_interval_ns: u64,

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn init(alloc: std.mem.Allocator, path: []const u8, check_interval_ms: u64) !Self {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    const path_copy = try arena.allocator().dupe(u8, path);
    errdefer arena.allocator().free(path_copy);

    std.mem.replaceScalar(u8, path_copy, '\\', '/');

    const dirstr = std.fs.path.dirname(path_copy) orelse {
        std.log.err("Invalid path '{s}'", .{path_copy});
        return error.InvalidPath;
    };
    const filename = std.fs.path.basename(path_copy);

    var dir = std.fs.openDirAbsolute(dirstr, .{}) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ dirstr, err });
        return error.DirectoryNotFound;
    };
    defer dir.close();

    const stat = dir.statFile(filename) catch |err| {
        std.log.err("Failed to stat file '{s}': {}", .{ filename, err });
        return error.FileNotFound;
    };

    return Self {
        .arena = arena,
        .dir = dirstr,
        .filename = filename,
        .last_modified = stat.mtime,
        .last_check_time = try std.time.Instant.now(),
        .check_interval_ns = check_interval_ms * std.time.ns_per_ms,
    };
}

pub fn was_modified_since_last_check(self: *Self) bool {
    const now = std.time.Instant.now() catch { return false; };
    if (now.since(self.last_check_time) < self.check_interval_ns) {
        return false;
    }
    self.last_check_time = now;

    var dir = std.fs.openDirAbsolute(self.dir, .{}) catch |err| {
        std.log.err("Failed to open directory '{s}': {}", .{ self.dir, err });
        return false;
    };
    defer dir.close();

    const stat = dir.statFile(self.filename) catch |err| {
        std.log.err("Failed to stat file '{s}': {}", .{ self.filename, err });
        return false;
    };

    const modified = stat.mtime != self.last_modified;
    self.last_modified = stat.mtime;
    return modified;
}

pub fn construct_path(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    return std.mem.join(alloc, "/", &.{ self.dir, self.filename });
}

const Self = @This();

const std = @import("std");

arena: std.heap.ArenaAllocator,
dirstr: []const u8,
dir: std.fs.Dir,
filename: ?[]const u8,
last_modified: i128,
last_check_time: std.time.Instant,
check_interval_ns: u64,

pub fn deinit(self: *Self) void {
    self.dir.close();
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

    var parent_dir = try std.fs.openDirAbsolute(dirstr, .{});
    defer parent_dir.close();

    const filename: []const u8 = std.fs.path.basename(path_copy);

    const file_stat: ?std.fs.Dir.Stat = parent_dir.statFile(filename) catch |err| blk: {
        if (err == std.fs.Dir.StatFileError.IsDir) {
            break :blk null;
        }
        return err;
    };

    const is_file = file_stat != null;

    var dir = 
        if (is_file) try std.fs.openDirAbsolute(dirstr, .{ .iterate = true, })
        else try std.fs.openDirAbsolute(path_copy, .{ .iterate = true, });
    errdefer dir.close();

    var self = Self {
        .arena = arena,
        .dir = dir,
        .dirstr = if (is_file) dirstr else path_copy,
        .filename = if (is_file) filename else null,
        .last_modified = undefined,
        .last_check_time = try std.time.Instant.now(),
        .check_interval_ns = check_interval_ms * std.time.ns_per_ms,
    };

    self.last_modified = self.stat_latest_modify_time() catch |err| {
        std.log.err("Failed to get stat in file watch '{s}|{s}': {}", .{
            self.dirstr,
            self.filename orelse "<null>",
            err
        });
        return err;
    };

    return self;
}

fn stat_latest_modify_time(self: *const Self) !i128 {
    if (self.filename) |f| {
        const stat = try self.dir.statFile(f);
        return stat.mtime;
    } else {
        var latest_mtime: i128 = 0;

        var iter = self.dir.iterate();
        while (true) {
            const entry = iter.next() catch break orelse break;
            if (entry.kind == .file) {
                const stat = try self.dir.statFile(entry.name);
                latest_mtime = @max(stat.mtime, latest_mtime);
            }
        }

        if (latest_mtime == 0) {
            return error.NoFilesExistInDirectory;
        }

        return latest_mtime;
    }
}

pub fn was_modified_since_last_check(self: *Self) bool {
    const now = std.time.Instant.now() catch { return false; };
    if (now.since(self.last_check_time) < self.check_interval_ns) {
        return false;
    }
    self.last_check_time = now;

    const new_mtime = self.stat_latest_modify_time() catch |err| {
        std.log.err("Failed to get stat in file watch '{s}|{s}': {}", .{
            self.dirstr,
            self.filename orelse "<null>",
            err
        });
        return false;
    };

    const modified = new_mtime > self.last_modified;
    self.last_modified = new_mtime;

    if (modified) { std.log.info("{s}|{s} was modified!", .{
            self.dirstr,
            self.filename orelse "<null>",
    }); }
    return modified;
}

pub fn construct_path(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    return std.mem.join(alloc, "/", &.{ self.dir, self.filename });
}

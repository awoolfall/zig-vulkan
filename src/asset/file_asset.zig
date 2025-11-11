const std = @import("std");
const eng = @import("../root.zig");
const pt = eng.path;
const FileWatcher = @import("file_watcher.zig");

pub const FileAsset = struct {
    const Self = @This();
    pub const BaseType = void;
    pub const Path = []const u8;

    alloc: std.mem.Allocator,
    path: Self.Path,
    watcher: FileWatcher,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.path.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, path: Self.Path) !Self {
        const owned_path = alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);

        return .{
            .alloc = alloc,
            .path = owned_path,
            .watcher = FileWatcher.init(alloc, owned_path, 500),
        };
    }

    pub fn loaded_asset(self: *Self) ?*Self.BaseType {
        _ = self;
        return null;
    }

    pub fn file_watcher(self: *Self) ?*FileWatcher {
        return &self.watcher;
    }

    pub fn unload(self: *Self) void {
        _ = self;
    }

    pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
        _ = self;
        _ = alloc;
    }

    pub fn reload(self: *Self, alloc: std.mem.Allocator) !void {
        _ = self;
        _ = alloc;
    }
};
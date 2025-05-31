const std = @import("std");
const eng = @import("../root.zig");

pub const PathOption = union(enum) {
    ExeRelative: []const u8,
    CwdRelative: []const u8,
    Absolute: []const u8,
    Asset: []const u8,
};

pub const Path = struct {
    arena: std.heap.ArenaAllocator,
    path: PathOption,

    pub fn deinit(self: *const Path) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, option: PathOption) !Path {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        const aalloc = arena.allocator();
        const owned_option = switch (option) {
            .ExeRelative => |e| PathOption{ .ExeRelative = try aalloc.dupe(u8, e) },
            .CwdRelative => |e| PathOption{ .CwdRelative = try aalloc.dupe(u8, e) },
            .Absolute => |e| PathOption{ .Absolute = try aalloc.dupe(u8, e) },
            .Asset => |e| PathOption{ .Asset = try aalloc.dupe(u8, e) },
        };

        return Path {
            .arena = arena,
            .path = owned_option,
        };
    }

    pub fn resolve_path(self: *const Path, alloc: std.mem.Allocator) ![]u8 {
        switch (self.path) {
            .ExeRelative => |v| {
                const exe_path = try std.fs.selfExeDirPathAlloc(alloc);
                defer alloc.free(exe_path);

                return try std.fs.path.resolve(alloc, &.{ exe_path, v }); 
            },
            .CwdRelative => |v| { return try alloc.dupe(u8, v); },
            .Absolute => |v| { return try alloc.dupe(u8, v); }, 
            .Asset => |v| { return try eng.get().asset_manager.resolve_asset_path(alloc, v); }, 
        }
    }

    pub fn resolve_path_c_str(self: *const Path, alloc: std.mem.Allocator) ![:0]u8 {
        const resolved_path = try self.resolve_path(alloc);
        defer alloc.free(resolved_path);

        return try alloc.dupeZ(u8, resolved_path);
    }
};


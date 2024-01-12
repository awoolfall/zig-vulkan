const std = @import("std");

pub const Path = union(enum) {
    ExeRelative: []const u8,
    CwdRelative: []const u8,
    Absolute: []const u8,

    pub fn resolve_path(self: *const Path, alloc: std.mem.Allocator) ![]u8 {
        switch (self.*) {
            .ExeRelative => |v| {
                const exe_path = try std.fs.selfExeDirPathAlloc(alloc);
                defer alloc.free(exe_path);

                return try std.fs.path.resolve(alloc, &.{ exe_path, v }); 
            },
            .CwdRelative => |v| { return try alloc.dupe(u8, v); },
            .Absolute => |v| { return try alloc.dupe(u8, v); }, 
        }
    }

    pub fn resolve_path_c_str(self: *const Path, alloc: std.mem.Allocator) ![:0]u8 {
        const resolved_path = try self.resolve_path(alloc);
        defer alloc.free(resolved_path);

        const sentinel_path = try alloc.alloc(u8, resolved_path.len + 1);
        @memcpy(sentinel_path[0..resolved_path.len], resolved_path[0..]);
        sentinel_path[sentinel_path.len - 1] = 0;

        return sentinel_path[0..resolved_path.len:0];
    }
};


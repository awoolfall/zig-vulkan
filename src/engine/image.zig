const std = @import("std");
const stbi = @import("zstbi");
const path = @import("path.zig");

pub const Image = stbi.Image;

pub const ImageLoader = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    pub fn deinit(self: *Self) void {
        _ = self;
        stbi.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !Self {
        stbi.init(alloc);

        return Self {
            .alloc = alloc,
        };
    }

    pub fn load_from_file(alloc: std.mem.Allocator, file_path: path.Path) !Image {
        const cpath = try file_path.resolve_path_c_str(alloc);
        defer alloc.free(cpath);

        return try stbi.Image.loadFromFile(cpath, 4);
    }

    pub fn load_from_memory(self: *const Self, data: []const u8) !Image {
        _ = self;
        return try stbi.Image.loadFromMemory(data, 4);
    }
};

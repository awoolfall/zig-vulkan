const std = @import("std");
const eng = @import("self");
const ms = eng.mesh;

const Self = @This();

pub const BaseType = ms.Model;
pub const Loader = Self;

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return Self {};
}

pub fn load(self: *Self, alloc: std.mem.Allocator, asset_uri: []const u8) !BaseType {
    _ = self;

    const uri = try std.Uri.parse(asset_uri);

    if (!std.mem.eql(u8, uri.scheme, "res")) {
        return error.AssetIsNotAResourceFile;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const asset_relative_path = try uri.path.toRawMaybeAlloc(arena.allocator());

    const asset_path = try eng.get().asset_manager.resolve_resource_relative_path(alloc, asset_relative_path);
    defer alloc.free(asset_path);

    return try ms.Model.init_from_file_assimp(
        alloc, 
        asset_path
    );
}

pub fn unload(self: *Self, asset: *BaseType) void {
    _ = self;
    asset.deinit();
}

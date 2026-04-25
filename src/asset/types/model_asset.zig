const std = @import("std");
const eng = @import("self");
const ms = eng.mesh;

const Self = @This();

pub const BaseType = ms.Model;
pub const Loader = Self;
pub const extensions = [_][]const u8{ ".glb", ".gltf", ".fbx" };

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return Self {};
}

pub fn load(self: *Self, alloc: std.mem.Allocator, asset_uri: []const u8) !BaseType {
    _ = self;

    const file_path = try eng.util.uri.resolve_file_uri(alloc, asset_uri);
    defer alloc.free(file_path);

    return try ms.Model.init_from_file_assimp(
        alloc, 
        file_path
    );
}

pub fn unload(self: *Self, asset: *BaseType) void {
    _ = self;
    asset.deinit();
}

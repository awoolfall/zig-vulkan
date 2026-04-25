const std = @import("std");
const eng = @import("self");
const FileWatcher = @import("../file_watcher.zig");

const ModelAsset = eng.assets.ModelAsset;

pub const AnimationPointer = struct {
    model_id: eng.assets.ModelAssetId,
    animation_id: usize,

    pub fn get(self: AnimationPointer) !*eng.animation.QuantisedBoneAnimation {
        const model: *eng.mesh.Model = try eng.get().asset_manager.get_asset(ModelAsset, self.model_id);
        return &model.animations[self.animation_id];
    }
};

const Self = @This();

pub const BaseType = AnimationPointer;
pub const Loader = Self;
pub const extensions = [_][]const u8{};

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;

    return Self {};
}

pub fn load(self: *Self, alloc: std.mem.Allocator, asset_uri: []const u8) !BaseType {
    // asset uri for animations will be: res:model_asset/animations/animation_name
    _ = self;

    const uri = try std.Uri.parse(asset_uri);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var path = try uri.path.toRawMaybeAlloc(arena.allocator());
    const animation_name = std.fs.path.basename(path);

    path = std.fs.path.dirname(path) orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, std.fs.path.basename(path), "animations")) {
        return error.InvalidFormat;
    }

    path = std.fs.path.dirname(path) orelse return error.InvalidFormat;

    const base_model_uri = try std.fmt.allocPrint(arena.allocator(), "{s}:{s}", .{ uri.scheme, path });
    defer arena.allocator().free(base_model_uri);

    const model_asset_id = try eng.get().asset_manager.get_asset_id(ModelAsset, base_model_uri);

    const model: *eng.mesh.Model = try eng.get().asset_manager.get_asset(ModelAsset, model_asset_id);

    const animation_idx = for (model.animations, 0..) |animation, idx| {
        if (std.mem.eql(u8, animation.name, animation_name)) {
            break idx;
        }
    } else return error.AnimationDoesNotExistInModel;

    return BaseType {
        .model_id = model_asset_id,
        .animation_id = animation_idx,
    };
}

pub fn unload(self: *Self, asset: *BaseType) void {
    _ = self;
    _ = asset;
}

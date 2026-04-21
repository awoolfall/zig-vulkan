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

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;

    return Self {};
}

pub fn load(self: *Self, alloc: std.mem.Allocator, asset_uri: []const u8) !BaseType {
    // asset uri for animations will be: asset://model_pretty_name#animation_name
    _ = self;

    const uri = try std.Uri.parse(asset_uri);

    if (!std.mem.eql(u8, uri.scheme, "asset")) {
        return error.NotAnAssetUri;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const host_model_pretty_name = try uri.getHostAlloc(arena.allocator());

    const animation_name_component: std.Uri.Component = try uri.fragment orelse return error.UriContainsNoFragment;
    const animation_name = try animation_name_component.toRawMaybeAlloc(arena.allocator());

    const model_asset_id = try eng.get().asset_manager.get_asset_id_from_pretty_name(ModelAsset, host_model_pretty_name);

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

const std = @import("std");
const eng = @import("self");
const FileWatcher = @import("../file_watcher.zig");

const ModelAsset = @import("model_asset.zig").ModelAsset;
const ModelAssetId = @import("../asset_id.zig").AssetId(ModelAsset);

const AnimationPath = struct {
    model_id: ModelAssetId,
    animation_id: u64,

    
    pub fn get_animation(self: *const AnimationPath) !*eng.animation.BoneAnimation {
        const model = try eng.get().asset_manager.get_asset(ModelAsset, self.model_id);
        if (self.animation_id >= model.animations.len) {
            return error.AnimationIdOutOfBounds;
        }
        return &model.animations[self.animation_id];
    }
};

pub const AnimationAsset = struct {
    const Self = @This();
    pub const BaseType = AnimationPath;
    pub const Path = AnimationPath;

    animation: BaseType,

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator, path: Self.Path) !Self {
        _ = alloc;

        return .{
            .animation = path,
        };
    }

    pub fn loaded_asset(self: *Self) ?*BaseType {
        return &self.animation;
    }

    pub fn file_watcher(self: *Self) ?*FileWatcher {
        _ = self;
        return null;
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


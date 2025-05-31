const std = @import("std");
const eng = @import("../root.zig");
const an = @import("../engine/animation.zig");
const FileWatcher = @import("file_watcher.zig");

const ModelAsset = @import("model_asset.zig").ModelAsset;
const ModelAssetId = @import("asset_id.zig").AssetId(ModelAsset);

pub const AnimationAsset = struct {
    const Self = @This();
    pub const BaseType = struct {
        base_model: ModelAssetId,
        animation_id: u64,

        pub fn get_animation(self: *const Self.BaseType) !*an.BoneAnimation {
            const model = try eng.get().asset_manager.get_asset(ModelAsset, self.base_model);
            if (self.animation_id >= model.animations.len) {
                return error.AnimationIdOutOfBounds;
            }
            return &model.animations[self.animation_id];
        }
    };

    animation: BaseType,

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn init(model_id: ModelAssetId, animation_id: u64) !Self {
        return .{
            .animation = .{
                .base_model = model_id,
                .animation_id = animation_id,
            },
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


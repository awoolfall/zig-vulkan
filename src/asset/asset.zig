pub const FileWatcher = @import("file_watcher.zig");
pub const AssetManager = @import("asset_manager.zig");

pub const GenericAssetId = @import("asset_id.zig");

pub const ModelAsset = @import("types/model_asset.zig");
pub const AnimationAsset = @import("types/animation_asset.zig");
pub const ImageAsset = @import("types/image_asset.zig");

pub const StandardAssets = .{
    ModelAsset,
    AnimationAsset,
    ImageAsset,
};

pub const ModelAssetId = GenericAssetId;
pub const AnimationAssetId = GenericAssetId;
pub const ImageAssetId = GenericAssetId;

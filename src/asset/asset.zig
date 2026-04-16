pub const FileWatcher = @import("file_watcher.zig");
pub const AssetManager = @import("asset_manager.zig");
pub const AssetPack = @import("asset_pack.zig");

pub const AssetPackId = usize;

pub const AssetId = @import("asset_id.zig").AssetId;

pub const ModelAsset = @import("types/model_asset.zig").ModelAsset;
pub const AnimationAsset = @import("types/animation_asset.zig").AnimationAsset;
pub const ImageAsset = @import("types/image_asset.zig").ImageAsset;

pub const ModelAssetId = AssetId(ModelAsset);
pub const AnimationAssetId = AssetId(AnimationAsset);
pub const ImageAssetId = AssetId(ImageAsset);

const std = @import("std");
const en = @import("../root.zig");

const AssetPack = @import("asset_pack.zig");
const AssetPath = AssetPack.AssetPath;

const AssetId = @import("asset_id.zig").AssetId;

const ModelAsset = @import("model_asset.zig").ModelAsset;
const AnimationAsset = @import("animation_asset.zig").AnimationAsset;
const Texture2DAsset = @import("texture2d_asset.zig").Texture2dAsset;

const Self = @This();

allocator: std.mem.Allocator,
resources_directory: []u8,

asset_packs: std.AutoArrayHashMap(u64, AssetPack),

pub fn deinit(self: *Self) void {
    // assert all asset packs have been unloaded before deinit
    var iter = self.asset_packs.iterator();
    while (iter.next()) |*entry| {
        if (entry.value_ptr.is_loaded) {
            std.log.warn("Asset Pack was not unloaded! {s}", .{ entry.value_ptr.unique_name });
            entry.value_ptr.unload();
        }
        entry.value_ptr.deinit();
    }

    self.asset_packs.deinit();
    self.allocator.free(self.resources_directory);
}

pub fn init(alloc: std.mem.Allocator, resources_dir: []const u8) !Self {
    return Self {
        .allocator = alloc,
        .asset_packs = std.AutoArrayHashMap(u64, AssetPack).init(alloc),
        .resources_directory = try alloc.dupe(u8, resources_dir),
    };
}

pub fn add_asset_pack(self: *Self, asset_pack: AssetPack) !u64 {
    try self.asset_packs.put(asset_pack.unique_name_hash, asset_pack);
    return asset_pack.unique_name_hash;
}

pub fn load_asset_pack(self: *Self, asset_pack_id: u64) !void {
    const asset_pack = self.asset_packs.getPtr(asset_pack_id) orelse return error.AssetPackDoesNotExist;
    try asset_pack.load(self.allocator);
}

pub fn unload_asset_pack(self: *Self, asset_pack_id: u64) !void {
    const asset_pack = self.asset_packs.getPtr(asset_pack_id) orelse return error.AssetPackDoesNotExist;
    asset_pack.unload();
}

pub fn resolve_asset_path(self: *const Self, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try alloc.dupe(u8, path);
    } else {
        return std.fs.path.join(alloc, &.{self.resources_directory, path});
    }
}

pub fn find_asset_id(self: *const Self, AssetType: type, asset_name: []const u8) ?AssetId(AssetType) {
    const asset_id = AssetId(AssetType).deserialize(asset_name) catch return null;
    _ = (self.get_asset(AssetType, asset_id) catch return null);
    return asset_id;
}

pub fn get_asset(self: *const Self, AssetType: type, asset_id: AssetId(AssetType)) !*AssetType.BaseType {
    const pack = self.asset_packs.getPtr(asset_id.pack_id)
        orelse return error.AssetPackDoesNotExist;

    const asset_hashmap = try pack.get_asset_hashmap(AssetType);

    const asset_path = asset_hashmap.getPtr(asset_id.asset_id) 
        orelse return error.AssetDoesNotExistInPack;

    if (asset_path.asset.file_watcher()) |watcher| {
        if (watcher.was_modified_since_last_check()) {
            asset_path.asset.reload(self.allocator) catch |err| {
                std.log.warn("Unable to reload asset: {}", .{err});
            };
        }
    }

    return asset_path.asset.loaded_asset() 
        orelse error.AssetNotLoaded;
}

// pub fn find_animation_id(self: *const Self, animation_name: []const u8) ?AnimationAssetId {
//     const animation_name_hash = std.hash_map.hashString(animation_name);
//     for (self.loaded_asset_packs.data.items, 0..) |*it, idx| {
//         if (it.item_data) |*pack| {
//             if (pack.animations.contains(animation_name_hash)) {
//                 return AnimationAssetId {
//                     .asset_id = .{
//                         .asset_pack_id = gen.GenerationalIndex {
//                             .index = idx,
//                             .generation = it.generation,
//                         },
//                         .id = animation_name_hash,
//                     },
//                 };
//             }
//         }
//     }
//     return null;
// }
//
// pub fn get_animation(self: *const Self, animation_id: AnimationAssetId) !*an.BoneAnimation {
//     const pack = self.loaded_asset_packs.get(animation_id.asset_id.asset_pack_id) orelse return error.AssetPackNotLoaded;
//     const aa = try (pack.animations.getPtr(animation_id.asset_id.id) orelse error.AnimationDoesNotExistInPack);
//     const lm = try (pack.models.getPtr(aa.model) orelse error.ModelDoesNotExistInPack);
//     return &lm.model.animations[aa.animation];
// }
//

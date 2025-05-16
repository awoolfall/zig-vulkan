const std = @import("std");
const en = @import("../root.zig");

pub fn AssetId(comptime AssetType: type) type {
    const SerializeSplitChar = '|';
    return struct {
        pack_id: u64,
        asset_id: u64,

        pub fn eql(self: AssetId(AssetType), other: AssetId(AssetType)) bool {
            return self.pack_id == other.pack_id and self.asset_id == other.asset_id;
        }

        pub fn serialize(self: *const AssetId(AssetType), alloc: std.mem.Allocator) ![]u8 {
            const asset_manager = &en.engine().asset_manager;

            const pack = asset_manager.asset_packs.getPtr(self.pack_id) orelse return error.AssetPackNotLoaded;
            const asset_hashmap = try pack.get_asset_hashmap(AssetType);

            const asset = asset_hashmap.get(self.asset_id) orelse return error.AssetNotFound;

            return try std.mem.join(alloc, &[_]u8{ SerializeSplitChar }, &[_][]const u8{ pack.unique_name, asset.unique_name });
        }

        pub fn deserialize(serialized_string: []const u8) !AssetId(AssetType) {
            var split_iter = std.mem.splitScalar(u8, serialized_string, SerializeSplitChar);
            const pack_name = split_iter.next() orelse return error.MalformedAssetString;
            const asset_name = split_iter.next() orelse return error.MalformedAssetString;

            return AssetId(AssetType) {
                .pack_id = std.hash_map.hashString(pack_name),
                .asset_id = std.hash_map.hashString(asset_name),
            };
        }

        pub const Serde = struct {
            pub const T = []const u8;

            pub fn serialize(alloc: std.mem.Allocator, asset_id: AssetId(AssetType)) !T {
                return asset_id.serialize(alloc);
            }

            pub fn deserialize(alloc: std.mem.Allocator, serialized: T) !AssetId(AssetType) {
                _ = alloc;
                return AssetId(AssetType).deserialize(serialized);
            }
        };
    };
}


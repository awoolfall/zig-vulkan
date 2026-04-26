const std = @import("std");
const eng = @import("self");

const Self = @This();

unique_id: u64,

pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
    const asset_metadata = eng.get().asset_manager.asset_metadata.get(value.unique_id) orelse return error.AssetIdDoesNotExistInAssetManager;
    return std.json.Value { .string = try alloc.dupe(u8, asset_metadata.uri) };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    _ = alloc;
    const asset_uri = switch (value) {
        .string => |s| s,
        else => return error.InvalidType,
    };
    const asset_unique_id = try eng.get().asset_manager.get_asset_unique_id(asset_uri);
    return .{ .unique_id = asset_unique_id };
}

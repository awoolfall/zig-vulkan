const std = @import("std");
const en = @import("../root.zig");
const assets = @import("asset.zig");

const AssetPack = @import("asset_pack.zig");
const AssetPath = AssetPack.AssetPath;

const AssetId = @import("asset_id.zig").AssetId;

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

pub fn resolve_asset_path(self: *const Self, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try alloc.dupe(u8, path);
    } else {
        return std.fs.path.join(alloc, &.{self.resources_directory, path});
    }
}

pub fn find_asset_id(self: *const Self, AssetType: type, asset_name: []const u8) !AssetId(AssetType) {
    const asset_id = try AssetId(AssetType).from_string_identifier(asset_name);
    _ = try self.get_asset(AssetType, asset_id);
    return asset_id;
}

pub fn get_asset_entry(self: *const Self, AssetType: type, asset_id: AssetId(AssetType)) !*AssetType {
    const pack = self.asset_packs.getPtr(asset_id.pack_id)
        orelse return error.AssetPackDoesNotExist;

    const asset_path = pack.assets.getPtr(asset_id.asset_id) 
        orelse return error.AssetDoesNotExistInPack;

    return try asset_path.asset.get(AssetType);
}

pub fn get_asset(self: *const Self, AssetType: type, asset_id: AssetId(AssetType)) !*AssetType.BaseType {
    const asset = try self.get_asset_entry(AssetType, asset_id);

    if (asset.file_watcher()) |watcher| {
        if (watcher.was_modified_since_last_check()) {
            asset.reload(self.allocator) catch |err| {
                std.log.warn("Unable to reload asset: {}", .{err});
            };
        }
    }

    return asset.loaded_asset() orelse error.AssetNotLoaded;
}


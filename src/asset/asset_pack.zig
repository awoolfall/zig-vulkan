const Self = @This();

const std = @import("std");
const AssetId = @import("asset_id.zig").AssetId;
const ma = @import("model_asset.zig");
const ta = @import("texture2d_asset.zig");
const aa = @import("animation_asset.zig");

pub fn AssetPath(comptime T: type) type {
    return struct {
        unique_name: []u8,
        asset: T,
    };
}

alloc: std.mem.Allocator,

is_loaded: bool = false,

unique_name: []u8,
unique_name_hash: u64,

models: std.AutoHashMap(u64, AssetPath(ma.ModelAsset)),
animations: std.AutoHashMap(u64, AssetPath(aa.AnimationAsset)),
images: std.AutoHashMap(u64, AssetPath(ta.ImageAsset)),

pub fn deinit(self: *Self) void {
    self.alloc.free(self.unique_name);

    {
        var iter = self.models.valueIterator();
        while (iter.next()) |a| {
            self.alloc.free(a.unique_name);
            a.asset.deinit();
        }
        self.models.deinit();
    }
    {
        var iter = self.animations.valueIterator();
        while (iter.next()) |a| {
            self.alloc.free(a.unique_name);
        }
        self.animations.deinit();
    }
    {
        var iter = self.images.valueIterator();
        while (iter.next()) |a| {
            self.alloc.free(a.unique_name);
            a.asset.deinit();
        }
        self.images.deinit();
    }
}

pub fn init(alloc: std.mem.Allocator, unique_name: []const u8) !Self {
    const owned_unique_name = try alloc.dupe(u8, unique_name);
    errdefer alloc.free(owned_unique_name);

    return Self {
        .alloc = alloc,

        .unique_name = owned_unique_name,
        .unique_name_hash = std.hash_map.hashString(owned_unique_name),

        .models = std.AutoHashMap(u64, AssetPath(ma.ModelAsset)).init(alloc),
        .animations = std.AutoHashMap(u64, AssetPath(aa.AnimationAsset)).init(alloc),
        .images = std.AutoHashMap(u64, AssetPath(ta.ImageAsset)).init(alloc),
    };
}

pub fn unload(self: *Self) void {
    if (!self.is_loaded) { return; }

    {
        var iter = self.models.valueIterator();
        while (iter.next()) |a| {
            a.asset.unload();
        }
    }
    {
        var iter = self.images.valueIterator();
        while (iter.next()) |a| {
            a.asset.unload();
        }
    }

    self.is_loaded = false;
}

pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
    if (self.is_loaded) { return; }

    {
        var iter = self.models.valueIterator();
        while (iter.next()) |a| {
            // TODO: safely unload if one fails
            try a.asset.load(alloc);
        }
    }
    {
        var iter = self.images.valueIterator();
        while (iter.next()) |a| {
            try a.asset.load(alloc);
        }
    }

    self.is_loaded = true;
}

pub fn get_asset_hashmap(self: *Self, AssetType: type) !*std.AutoHashMap(u64, AssetPath(AssetType)) {
    switch (AssetType) {
        ma.ModelAsset => return &self.models,
        aa.AnimationAsset => return &self.animations,
        ta.ImageAsset => return &self.images,
        else => return error.InvalidAssetType,
    }
}

pub fn add_model(self: *Self, name: []const u8, path: ma.ModelAssetPath) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.models.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = try ma.ModelAsset.init(self.alloc, path),
        }
    );
}

pub fn define_animation(self: *Self, name: []const u8, base_model: []const u8, animation_id: usize) !void {
    const base_model_name_hash = std.hash_map.hashString(base_model);
    if (!self.models.contains(base_model_name_hash)) {
        return error.ModelDoesNotExistInAssetPack;
    }

    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.animations.put(
        std.hash_map.hashString(owned_name),
        .{
            .unique_name = owned_name,
            .asset = .{ 
                .animation = .{
                    .base_model = .{
                        .pack_id = self.unique_name_hash,
                        .asset_id = base_model_name_hash,
                    },
                    .animation_id = animation_id,
                },
            },
        }
    );
}

pub fn add_image(self: *Self, name: []const u8, path: ta.ImagePath) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.images.put(
        std.hash_map.hashString(owned_name),
        .{
            .unique_name = owned_name,
            .asset = try ta.ImageAsset.init(self.alloc, path),
        }
    );
}

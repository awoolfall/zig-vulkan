const Self = @This();

const std = @import("std");
const eng = @import("self");
const as = eng.assets;
const AssetId = @import("asset_id.zig").AssetId;

pub const AssetType = union(enum) {
    Model: as.ModelAsset,
    Animation: as.AnimationAsset,
    Image: as.ImageAsset,

    pub fn deinit(self: *AssetType) void {
        switch (self.*) {
            .Model => |*a| a.deinit(),
            .Animation => |*a| a.deinit(),
            .Image => |*a| a.deinit(),
        }
    }

    pub fn get(self: *AssetType, comptime A: type) !*A {
        switch (A) {
            as.ModelAsset => switch (self.*) {
                .Model => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            as.AnimationAsset => switch (self.*) {
                .Animation => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            as.ImageAsset => switch (self.*) {
                .Image => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            else => return error.NotAnAssetType,
        }
    }

    pub const Paths = union(enum) {
        Model: as.ModelAsset.Path,
        Animation: struct { model_name: []const u8, animation_id: u64, },
        Image: as.ImageAsset.Path,
    };

    pub fn load(self: *AssetType, alloc: std.mem.Allocator) !void {
        try switch (self.*) {
            .Model => |*a| a.load(alloc),
            .Animation => |*a| a.load(alloc),
            .Image => |*a| a.load(alloc),
        };
    }
    
    pub fn unload(self: *AssetType) void {
        switch (self.*) {
            .Model => |*a| a.unload(),
            .Animation => |*a| a.unload(),
            .Image => |*a| a.unload(),
        }
    }
};

pub const Asset = struct {
    unique_name: []const u8,
    asset: AssetType,

    pub fn deinit(self: *Asset, alloc: std.mem.Allocator) void {
        alloc.free(self.unique_name);
        self.asset.deinit();
    }

    pub fn load(self: *Asset, alloc: std.mem.Allocator) !void {
        try self.asset.load(alloc);
    }

    pub fn unload(self: *Asset) void {
        self.asset.unload();
    }
};

alloc: std.mem.Allocator,

is_loaded: bool = false,

unique_name: []u8,
unique_name_hash: u64,

assets: std.AutoHashMap(u64, Asset),

pub fn deinit(self: *Self) void {
    self.alloc.free(self.unique_name);

    var asset_iter = self.assets.valueIterator();
    while (asset_iter.next()) |a| {
        a.deinit(self.alloc);
    }
    self.assets.deinit();
}

pub fn init(alloc: std.mem.Allocator, unique_name: []const u8) !Self {
    const owned_unique_name = try alloc.dupe(u8, unique_name);
    errdefer alloc.free(owned_unique_name);

    return Self {
        .alloc = alloc,

        .unique_name = owned_unique_name,
        .unique_name_hash = std.hash_map.hashString(owned_unique_name),

        .assets = std.AutoHashMap(u64, Asset).init(alloc),
    };
}

pub fn unload(self: *Self) void {
    if (!self.is_loaded) { return; }

    var asset_iter = self.assets.valueIterator();
    while (asset_iter.next()) |a| {
        a.unload();
    }

    self.is_loaded = false;
}

pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
    if (self.is_loaded) { return; }

    var asset_iter = self.assets.valueIterator();
    while (asset_iter.next()) |a| {
        // TODO: safely unload if one fails
        try a.load(alloc);
    }

    self.is_loaded = true;
}

pub fn add_model(self: *Self, name: []const u8, path: as.ModelAsset.Path) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    var model_asset = AssetType { .Model = try as.ModelAsset.init(self.alloc, path), };
    if (self.is_loaded) {
        try model_asset.load(self.alloc);
    }
    errdefer model_asset.unload();

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = model_asset,
        },
    );
}

pub fn define_animation(self: *Self, name: []const u8, base_model: []const u8, animation_id: usize) !void {
    const model_asset_id = AssetId(as.ModelAsset) {
        .pack_id = self.unique_name_hash,
        .asset_id = std.hash_map.hashString(base_model),
    };

    if (!self.assets.contains(model_asset_id.asset_id)) {
        return error.ModelDoesNotExistInAssetPack;
    }

    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    var animation_asset = AssetType { .Animation = try as.AnimationAsset.init(self.alloc, .{
        .model_id = model_asset_id,
        .animation_id = animation_id,
    }), };
    if (self.is_loaded) {
        try animation_asset.load(self.alloc);
    }
    errdefer animation_asset.unload();

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = animation_asset,
        },
    );
}

pub fn add_image(self: *Self, name: []const u8, path: as.ImageAsset.Path) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    var image_asset = AssetType { .Image = try as.ImageAsset.init(self.alloc, path), };
    if (self.is_loaded) {
        try image_asset.load(self.alloc);
    }
    errdefer image_asset.unload();

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = image_asset,
        },
    );
}

const AssetSerialized = struct {
    name: []const u8,
    path: AssetType.Paths,
};

pub fn init_from_buffer(alloc: std.mem.Allocator, pack_name: []const u8, data: [:0]const u8) !Self {
    var arena_struct = std.heap.ArenaAllocator.init(alloc);
    defer arena_struct.deinit();
    const arena = arena_struct.allocator();

    var zon_diag = std.zon.parse.Diagnostics {};
    const pack_data = std.zon.parse.fromSlice([]const AssetSerialized, arena, data, &zon_diag, .{}) catch |err| {
        std.log.err("Failed to load asset pack '{s}'\n{any}", .{pack_name, zon_diag});
        return err;
    };

    var pack = try Self.init(alloc, pack_name);
    errdefer pack.deinit();

    for (pack_data) |asset| {
        switch (asset.path) {
            .Model => |p| try pack.add_model(asset.name, p),
            .Animation => |p| try pack.define_animation(asset.name, p.model_name, p.animation_id),
            .Image => |p| try pack.add_image(asset.name, p),
        }
    }

    return pack;
}

pub fn init_from_file(alloc: std.mem.Allocator, pack_name: []const u8, file_path: []const u8) !Self {
    var arena_struct = std.heap.ArenaAllocator.init(alloc);
    defer arena_struct.deinit();
    const arena = arena_struct.allocator();

    const file_stat = try std.fs.cwd().statFile(file_path);

    const file_slice = try std.fs.cwd().readFileAlloc(arena, file_path, file_stat.size);
    defer arena.free(file_slice);

    const file_slice_0 = try std.mem.concatWithSentinel(arena, u8, &.{ file_slice }, 0);
    defer arena.free(file_slice_0);

    return try Self.init_from_buffer(alloc, pack_name, file_slice_0);
}

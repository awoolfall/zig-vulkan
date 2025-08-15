const Self = @This();

const std = @import("std");
const eng = @import("self");
const AssetId = @import("asset_id.zig").AssetId;

const ma = @import("model_asset.zig");
const ta = @import("texture2d_asset.zig");
const aa = @import("animation_asset.zig");

pub const AssetType = union(enum) {
    Model: ma.ModelAsset,
    Animation: aa.AnimationAsset,
    Image: ta.ImageAsset,

    pub fn get(self: *AssetType, comptime A: type) !*A {
        switch (A) {
            ma.ModelAsset => switch (self.*) {
                .Model => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            aa.AnimationAsset => switch (self.*) {
                .Animation => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            ta.ImageAsset => switch (self.*) {
                .Image => |*a| return a,
                else => return error.AssetTypeMismatch,
            },
            else => return error.NotAnAssetType,
        }
    }

    pub const Paths = union(enum) {
        Model: ma.ModelAsset.Path,
        Animation: struct { model_name: []const u8, animation_id: u64, },
        Image: ta.ImageAsset.Path,
    };
};

pub const Asset = struct {
    unique_name: []const u8,
    asset: AssetType,

    pub fn deinit(self: *Asset, alloc: std.mem.Allocator) void {
        alloc.free(self.unique_name);
        switch (self.asset) {
            .Model => |*a| a.deinit(),
            .Animation => |*a| a.deinit(),
            .Image => |*a| a.deinit(),
        }
    }

    pub fn load(self: *Asset, alloc: std.mem.Allocator) !void {
        try switch (self.asset) {
            .Model => |*a| a.load(alloc),
            .Animation => |*a| a.load(alloc),
            .Image => |*a| a.load(alloc),
        };
    }

    pub fn unload(self: *Asset) void {
        switch (self.asset) {
            .Model => |*a| a.unload(),
            .Animation => |*a| a.unload(),
            .Image => |*a| a.unload(),
        }
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

pub fn add_model(self: *Self, name: []const u8, path: ma.ModelAssetPath) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = .{ .Model = try ma.ModelAsset.init(self.alloc, path), },
        },
    );
}

pub fn define_animation(self: *Self, name: []const u8, base_model: []const u8, animation_id: usize) !void {
    const model_asset_id = AssetId(ma.ModelAsset) {
        .pack_id = self.unique_name_hash,
        .asset_id = std.hash_map.hashString(base_model),
    };

    if (!self.assets.contains(model_asset_id.asset_id)) {
        return error.ModelDoesNotExistInAssetPack;
    }

    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = .{ .Animation = try aa.AnimationAsset.init(self.alloc, .{
                .model_id = model_asset_id,
                .animation_id = animation_id,
            }), },
        },
    );
}

pub fn add_image(self: *Self, name: []const u8, path: ta.ImagePath) !void {
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);

    try self.assets.put(
        std.hash_map.hashString(owned_name), 
        .{
            .unique_name = owned_name,
            .asset = .{ .Image = try ta.ImageAsset.init(self.alloc, path), },
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

    var zon_status = std.zon.parse.Status {};
    const pack_data = std.zon.parse.fromSlice([]const AssetSerialized, arena, data, &zon_status, .{}) catch |err| {
        std.log.err("Failed to load asset pack '{s}'\n{}", .{pack_name, zon_status});
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

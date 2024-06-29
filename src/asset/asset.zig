const std = @import("std");
const ms = @import("../engine/mesh.zig");
const pt = @import("../engine/path.zig");
const gf = @import("../gfx/gfx.zig");
const gen = @import("../engine/entity.zig");

pub const AssetManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    loaded_asset_packs: gen.GenerationalList(LoadedAssetPack),
    resources_directory: []u8,

    pub fn deinit(self: *Self) void {
        // assert all asset packs have been unloaded before deinit
        std.debug.assert(self.num_loaded_asset_packs() == 0);

        self.loaded_asset_packs.deinit();
        self.allocator.free(self.resources_directory);
    }

    pub fn init(alloc: std.mem.Allocator, resources_dir: []const u8) !Self {
        return Self {
            .allocator = alloc,
            .loaded_asset_packs = try gen.GenerationalList(LoadedAssetPack).init(alloc),
            .resources_directory = try alloc.dupe(u8, resources_dir),
        };
    }

    pub fn load_asset_pack(self: *Self, alloc: std.mem.Allocator, asset_pack: *const AssetPack, gfx: *gf.GfxState) !AssetPackId {
        const asset_pack_id = try self.loaded_asset_packs.insert(LoadedAssetPack{
            .models = std.AutoHashMap(u64, ms.Model).init(alloc),
        });
        const loaded_asset_pack = try self.loaded_asset_packs.get(asset_pack_id);

        for (asset_pack.model_assets.items) |path| {
            const name_hash = std.hash_map.hashString(path.unique_name);

            // @TODO move actual loading of models to another thread
            switch (path.asset_path) {
                .Path => |p| {
                    const asset_path = try std.fs.path.join(alloc, &[_][]const u8{self.resources_directory, p});
                    defer alloc.free(asset_path);

                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.init_from_file_assimp(alloc, pt.Path{ .Absolute = asset_path }, gfx)
                    );
                },
                .Plane => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.plane(alloc, d.slices, d.stacks, gfx)
                    );
                },
                .Cone => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.cone(alloc, d.slices, gfx)
                    );
                },
            }
        }

        return asset_pack_id;
    }

    pub fn unload_asset_pack(self: *Self, asset_pack_id: AssetPackId) !void {
        const asset_pack = try self.loaded_asset_packs.get(asset_pack_id);
        asset_pack.deinit();
        try self.loaded_asset_packs.remove(asset_pack_id);
    }

    pub fn find_model_id(self: *const Self, model_name: []const u8) ?ModelAssetId {
        const model_name_hash = std.hash_map.hashString(model_name);
        for (self.loaded_asset_packs.data.items, 0..) |*it, idx| {
            if (it.item_data) |*pack| {
                if (pack.models.contains(model_name_hash)) {
                    return ModelAssetId {
                        .asset_id = .{
                            .asset_pack_id = gen.GenerationalIndex {
                                .index = idx,
                                .generation = it.generation,
                            },
                            .id = model_name_hash,
                        },
                    };
                }
            }
        }
        return null;
    }

    pub fn get_model(self: *const Self, model_id: ModelAssetId) !*ms.Model {
        const pack = try self.loaded_asset_packs.get(model_id.asset_id.asset_pack_id);
        return (pack.models.getPtr(model_id.asset_id.id) orelse error.ModelDoesNotExistInPack);
    }

    pub fn num_loaded_asset_packs(self: *const Self) usize {
        return self.loaded_asset_packs.item_count();
    }
};

pub const AssetPackId = gen.GenerationalIndex;

pub fn AssetPath(comptime T: type) type {
    return struct {
        unique_name: []u8,
        asset_path: T,
    };
}

pub const AssetPack = struct {
    arena: std.heap.ArenaAllocator,
    model_assets: std.ArrayList(AssetPath(ModelAsset)),

    pub fn deinit(self: *AssetPack) void {
        self.model_assets.deinit();
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) AssetPack {
        return AssetPack {
            .model_assets = std.ArrayList(AssetPath(ModelAsset)).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub const ModelAsset = union(enum) {
        Path: []const u8,
        Plane: struct {
            slices: i32,
            stacks: i32,
        },
        Cone: struct {
            slices: i32,
        },
    };

    pub fn add_model(self: *AssetPack, name: []const u8, path: ModelAsset) !void {
        const owned_name = try self.arena.allocator().dupe(u8, name);
        var owned_path = path;
        switch (path) {
            .Path => |p| { 
                owned_path = ModelAsset{ .Path = try self.arena.allocator().dupe(u8, p) };
            },
            else => {}
        }
        
        try self.model_assets.append(.{
            .unique_name = owned_name,
            .asset_path = owned_path,
        });
    }
};

pub const LoadedAssetPack = struct {
    models: std.AutoHashMap(u64, ms.Model),

    pub fn deinit(self: *LoadedAssetPack) void {
        var v_iter = self.models.valueIterator();
        while (v_iter.next()) |model| {
            model.deinit();
        }
        self.models.deinit();
    }
};

pub const AssetId = struct {
    asset_pack_id: gen.GenerationalIndex,
    id: u64,
};

pub const ModelAssetId = struct {
    asset_id: AssetId,
};

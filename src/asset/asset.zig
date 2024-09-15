const std = @import("std");
const ms = @import("../engine/mesh.zig");
const an = @import("../engine/animation.zig");
const pt = @import("../engine/path.zig");
const gf = @import("../gfx/gfx.zig");
const gen = @import("../engine/gen_list.zig");

pub const AssetManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    loaded_asset_packs: gen.GenerationalList(LoadedAssetPack),
    resources_directory: []u8,

    pub fn deinit(self: *Self) void {
        // assert all asset packs have been unloaded before deinit
        if (self.num_loaded_asset_packs() != 0) {
            std.log.warn("Not all asset packs have been unloaded before deinit!", .{});

            // deinit all remaining asset packs
            var iterator = self.loaded_asset_packs.iterator();
            while (iterator.next()) |pack| {
                pack.deinit();
            }
        }

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
            .models = std.AutoHashMap(u64, ?ms.Model).init(alloc),
            .animations = std.AutoHashMap(u64, LoadedAnimation).init(alloc),
        });
        const loaded_asset_pack = self.loaded_asset_packs.get(asset_pack_id) orelse return error.AssetPackNotLoaded;

        // models
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
                .PlaneOnSphere => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.plane_on_sphere(alloc, d.slices, d.stacks, d.plane_extent_radians, gfx)
                    );
                },
                .HeightMap => |h| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.heightmap_plane_on_sphere(alloc, &h.height_map, .{
                            .slices = h.slices,
                            .stacks = h.stacks,
                            .plane_extent_radians = h.plane_extent_radians,
                            .heightmap_scale = h.height_map_scale,
                        }, gfx)
                    );
                },
                .Cone => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.cone(alloc, d.slices, gfx)
                    );
                },
                .Sphere => |s| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.sphere(alloc, s.slices, s.stacks, gfx)
                    );
                },
            }
        }

        // animations
        for (asset_pack.animations.items) |path| {
            const name_hash = std.hash_map.hashString(path.unique_name);
            const base_model_name_hash = std.hash_map.hashString(asset_pack.model_assets.items[path.asset_path.base_model].unique_name);

            try loaded_asset_pack.animations.put(
                name_hash, 
                .{
                    .model = base_model_name_hash,
                    .animation = path.asset_path.animation_id,
                }
            );
        }

        return asset_pack_id;
    }

    pub fn unload_asset_pack(self: *Self, asset_pack_id: AssetPackId) !void {
        const asset_pack = self.loaded_asset_packs.get(asset_pack_id) orelse return error.AssetPackNotLoaded;
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
        const pack = self.loaded_asset_packs.get(model_id.asset_id.asset_pack_id) orelse return error.AssetPackNotLoaded;
        const mm = try (pack.models.getPtr(model_id.asset_id.id) orelse error.ModelDoesNotExistInPack);
        if (mm.*) |*m| {
            return m;
        } else {
            return error.ModelNotYetLoaded;
        }
    }

    pub fn find_animation_id(self: *const Self, animation_name: []const u8) ?AnimationAssetId {
        const animation_name_hash = std.hash_map.hashString(animation_name);
        for (self.loaded_asset_packs.data.items, 0..) |*it, idx| {
            if (it.item_data) |*pack| {
                if (pack.animations.contains(animation_name_hash)) {
                    return AnimationAssetId {
                        .asset_id = .{
                            .asset_pack_id = gen.GenerationalIndex {
                                .index = idx,
                                .generation = it.generation,
                            },
                            .id = animation_name_hash,
                        },
                    };
                }
            }
        }
        return null;
    }

    pub fn get_animation(self: *const Self, animation_id: AnimationAssetId) !*an.BoneAnimation {
        const pack = self.loaded_asset_packs.get(animation_id.asset_id.asset_pack_id) orelse return error.AssetPackNotLoaded;
        const aa = try (pack.animations.getPtr(animation_id.asset_id.id) orelse error.AnimationDoesNotExistInPack);
        const mm = try (pack.models.getPtr(aa.model) orelse error.ModelDoesNotExistInPack);
        if (mm.*) |*m| {
            return &m.animations[aa.animation];
        } else {
            return error.ModelNotYetLoaded;
        }
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
    animations: std.ArrayList(AssetPath(AnimationAsset)),

    pub fn deinit(self: *AssetPack) void {
        self.model_assets.deinit();
        self.animations.deinit();
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) AssetPack {
        return AssetPack {
            .model_assets = std.ArrayList(AssetPath(ModelAsset)).init(alloc),
            .animations = std.ArrayList(AssetPath(AnimationAsset)).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub const ModelAsset = union(enum) {
        Path: []const u8,
        Plane: struct {
            slices: i32 = 32,
            stacks: i32 = 32,
        },
        PlaneOnSphere: struct {
            slices: i32 = 32,
            stacks: i32 = 32,
            plane_extent_radians: f32,
        },
        HeightMap: struct {
            height_map: ms.Model.Heightmap,
            slices: i32 = 32,
            stacks: i32 = 32,
            plane_extent_radians: f32 = 0.0,
            height_map_scale: f32 = 1.0,
        },
        Cone: struct {
            slices: i32,
        },
        Sphere: struct {
            slices: i32,
            stacks: i32,
        },
    };

    pub const AnimationAsset = struct {
        base_model: usize,
        animation_id: usize,
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

    pub fn define_animation(self: *AssetPack, name: []const u8, base_model: []const u8, animation_id: usize) !void {
        const model_id = for (self.model_assets.items, 0..) |model, idx| {
            if (std.mem.eql(u8, model.unique_name, base_model)) {
                break idx;
            }
        } else {
            return error.ModelNotFound;
        };

        const owned_name = try self.arena.allocator().dupe(u8, name);
        try self.animations.append(.{
            .unique_name = owned_name,
            .asset_path = .{ 
                .base_model = model_id,
                .animation_id = animation_id,
            },
        });
    }
};

pub const LoadedAnimation = struct {
    model: u64,
    animation: usize,
};

pub const LoadedAssetPack = struct {
    models: std.AutoHashMap(u64, ?ms.Model),
    animations: std.AutoHashMap(u64, LoadedAnimation),

    pub fn deinit(self: *LoadedAssetPack) void {
        var m_iter = self.models.valueIterator();
        while (m_iter.next()) |model| {
            if (model.*) |*m| {
                m.deinit();
            }
        }
        self.models.deinit();

        self.animations.deinit();
    }
};

pub const AssetId = struct {
    asset_pack_id: gen.GenerationalIndex,
    id: u64,

    pub fn eql(self: AssetId, other: AssetId) bool {
        return self.asset_pack_id.eql(other.asset_pack_id) and self.id == other.id;
    }
};

pub const ModelAssetId = struct {
    asset_id: AssetId,
};

pub const AnimationAssetId = struct {
    asset_id: AssetId,
};

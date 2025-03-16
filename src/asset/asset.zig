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

    pub fn load_asset_pack(self: *Self, asset_pack: *const AssetPack, gfx: *gf.GfxState) !AssetPackId {
        const asset_pack_id = try self.loaded_asset_packs.insert(LoadedAssetPack{
            .allocator = self.allocator,
            .asset_names = std.AutoHashMap(u64, []const u8).init(self.allocator),
            .unique_name = try self.allocator.dupe(u8, asset_pack.unique_name),
            .unique_name_hash = asset_pack.unique_name_hash,
            .models = std.AutoHashMap(u64, ?ms.Model).init(self.allocator),
            .animations = std.AutoHashMap(u64, LoadedAnimation).init(self.allocator),
        });
        const loaded_asset_pack = self.loaded_asset_packs.get(asset_pack_id) orelse return error.AssetPackNotLoaded;

        // models
        for (asset_pack.model_assets.items) |path| {
            const name_hash = std.hash_map.hashString(path.unique_name);

            try loaded_asset_pack.asset_names.put(name_hash, try self.allocator.dupe(u8, path.unique_name));
            errdefer {
                self.allocator.free(loaded_asset_pack.asset_names.get(name_hash).?);
                _ = loaded_asset_pack.asset_names.remove(name_hash);
            }

            // @TODO move actual loading of models to another thread
            switch (path.asset_path) {
                .Path => |p| {
                    const asset_path = try std.fs.path.join(self.allocator, &[_][]const u8{self.resources_directory, p});
                    defer self.allocator.free(asset_path);

                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.init_from_file_assimp(self.allocator, pt.Path{ .Absolute = asset_path }, gfx)
                    );
                },
                .Plane => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.plane(self.allocator, d.slices, d.stacks, gfx)
                    );
                },
                .PlaneOnSphere => |d| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.plane_on_sphere(self.allocator, d.slices, d.stacks, d.plane_extent_radians, gfx)
                    );
                },
                .HeightMap => |h| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.heightmap_plane_on_sphere(self.allocator, &h.height_map, .{
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
                        try ms.Model.cone(self.allocator, d.slices, gfx)
                    );
                },
                .Sphere => |s| {
                    try loaded_asset_pack.models.put(
                        name_hash, 
                        try ms.Model.sphere(self.allocator, s.slices, s.stacks, gfx)
                    );
                },
            }
        }

        // animations
        for (asset_pack.animations.items) |path| {
            const name_hash = std.hash_map.hashString(path.unique_name);
            const base_model_name_hash = std.hash_map.hashString(asset_pack.model_assets.items[path.asset_path.base_model].unique_name);

            try loaded_asset_pack.asset_names.put(name_hash, try self.allocator.dupe(u8, path.unique_name));
            errdefer {
                self.allocator.free(loaded_asset_pack.asset_names.get(name_hash).?);
                _ = loaded_asset_pack.asset_names.remove(name_hash);
            }

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

    pub fn find_asset_pack_by_unique_name_id(self: *const Self, unique_name_hash: u64) ?AssetPackId {
        for (self.loaded_asset_packs.data.items, 0..) |*it, idx| {
            if (it.item_data) |*pack| {
                if (pack.unique_name_hash == unique_name_hash) {
                    return AssetPackId {
                        .index = idx,
                        .generation = it.generation,
                    };
                }
            }
        }
        return null;
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
    unique_name: []u8,
    unique_name_hash: u64,

    pub fn deinit(self: *AssetPack) void {
        self.model_assets.deinit();
        self.animations.deinit();
        self.arena.child_allocator.free(self.unique_name);
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, unique_name: []const u8) !AssetPack {
        return AssetPack {
            .model_assets = std.ArrayList(AssetPath(ModelAsset)).init(alloc),
            .animations = std.ArrayList(AssetPath(AnimationAsset)).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .unique_name = try alloc.dupe(u8, unique_name),
            .unique_name_hash = std.hash_map.hashString(unique_name),
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
            slices: i32 = 32,
            stacks: i32 = 16,
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
    allocator: std.mem.Allocator,
    models: std.AutoHashMap(u64, ?ms.Model),
    animations: std.AutoHashMap(u64, LoadedAnimation),
    asset_names: std.AutoHashMap(u64, []const u8),
    unique_name: []const u8,
    unique_name_hash: u64,

    pub fn deinit(self: *LoadedAssetPack) void {
        var name_iter = self.asset_names.valueIterator();
        while (name_iter.next()) |name| {
            self.allocator.free(name.*);
        }
        self.asset_names.deinit();

        var m_iter = self.models.valueIterator();
        while (m_iter.next()) |model| {
            if (model.*) |*m| {
                m.deinit();
            }
        }
        self.models.deinit();

        self.animations.deinit();

        self.allocator.free(self.unique_name);
    }

    pub fn get_asset_name(self: *const LoadedAssetPack, asset_id: u64) ?[]const u8 {
        return self.asset_names.get(asset_id);
    }
};

pub const AssetId = struct {
    asset_pack_id: gen.GenerationalIndex,
    id: u64,

    pub fn eql(self: AssetId, other: AssetId) bool {
        return self.asset_pack_id.eql(other.asset_pack_id) and self.id == other.id;
    }

    const SerializeSplitChar = '|';
    pub fn serialize(self: *const AssetId, alloc: std.mem.Allocator, asset_manager: *const AssetManager) ![]u8 {
        const pack = asset_manager.loaded_asset_packs.get(self.asset_pack_id) orelse return error.AssetPackNotLoaded;
        const pack_name = pack.unique_name;
        const asset_name = pack.get_asset_name(self.id) orelse return error.AssetNotFound;

        return try std.mem.join(alloc, &[_]u8{ SerializeSplitChar }, &[_][]const u8{ pack_name, asset_name });
    }

    pub fn deserialize(serialized_string: []const u8, asset_manager: *const AssetManager) !AssetId {
        var split_iter = std.mem.splitScalar(u8, serialized_string, SerializeSplitChar);
        const pack_name = split_iter.next() orelse return error.MalformedAssetString;
        const asset_name = split_iter.next() orelse return error.MalformedAssetString;

        return AssetId {
            .asset_pack_id = asset_manager.find_asset_pack_by_unique_name_id(std.hash_map.hashString(pack_name)) orelse return error.AssetPackNotLoaded,
            .id = std.hash_map.hashString(asset_name),
        };
    }
};

pub const ModelAssetId = struct {
    asset_id: AssetId,

    pub const Serde = struct {
        pub const T = []const u8;

        pub fn serialize(alloc: std.mem.Allocator, asset_id: ModelAssetId) !T {
            return asset_id.asset_id.serialize(alloc, &@import("../root.zig").engine().asset_manager);
        }

        pub fn deserialize(alloc: std.mem.Allocator, serialized: T) !ModelAssetId {
            _ = alloc;
            return ModelAssetId {
                .asset_id = try AssetId.deserialize(serialized, &@import("../root.zig").engine().asset_manager),
            };
        }
    };
};

pub const AnimationAssetId = struct {
    asset_id: AssetId,

    pub const Serde = struct {
        pub const T = []const u8;

        pub fn serialize(alloc: std.mem.Allocator, asset_id: AnimationAssetId) !T {
            return asset_id.asset_id.serialize(alloc, &@import("../root.zig").engine().asset_manager);
        }

        pub fn deserialize(alloc: std.mem.Allocator, serialized: T) !AnimationAssetId {
            _ = alloc;
            return AnimationAssetId {
                .asset_id = try AssetId.deserialize(serialized, &@import("../root.zig").engine().asset_manager),
            };
        }
    };
};

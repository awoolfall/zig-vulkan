const std = @import("std");
const en = @import("../root.zig");
const ms = en.mesh;
const pt = en.path;
const FileWatcher = @import("file_watcher.zig");

pub const ModelAssetPath = union(enum) {
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
    Cube: struct {},
};

pub const ModelAsset = struct {
    const Self = @This();
    pub const BaseType = ms.Model;

    arena: std.heap.ArenaAllocator,
    path: ModelAssetPath,

    loaded_model: ?struct {
        watcher: ?FileWatcher = null,
        model: ms.Model,
    } = null,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, path: ModelAssetPath) !Self {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var owned_path = path;
        switch (owned_path) {
            .Path => |p| { 
                owned_path = .{ 
                    .Path = try arena.allocator().dupe(u8, p)
                };
            },
            else => {},
        }

        return .{
            .arena = arena,
            .path = owned_path,
        };
    }

    pub fn loaded_asset(self: *Self) ?*ms.Model {
        const loaded_model = &(self.loaded_model orelse return null);
        return &loaded_model.model;
    }

    pub fn file_watcher(self: *Self) ?*FileWatcher {
        const loaded_model = &(self.loaded_model orelse return null);
        return &(loaded_model.watcher orelse return null);
    }

    pub fn unload(self: *Self) void {
        if (self.loaded_model) |*l| {
            if (l.watcher) |*w| {
                w.deinit();
            }
            l.model.deinit();
        }
    }

    pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
        if (self.loaded_model != null) { return error.AlreadyLoaded; }

        var watcher = switch (self.path) {
            .Path => |p| blk: {
                const asset_path = try en.engine().asset_manager.resolve_asset_path(alloc, p);
                defer alloc.free(asset_path);

                break :blk try FileWatcher.init(alloc, asset_path, 500);
            },
            else => null
        };
        errdefer if (watcher) |*w| { w.deinit(); };

        const model = try load_model(&self.path, alloc);
        errdefer model.deinit();

        self.loaded_model = .{
            .watcher = watcher,
            .model = model,
        };
    }

    pub fn reload(self: *Self, alloc: std.mem.Allocator) !void {
        const loaded_model = &(self.loaded_model orelse return);

        const new_model = try load_model(&self.path, alloc);
        errdefer new_model.deinit();

        loaded_model.model.deinit();
        loaded_model.model = new_model;
    }

    fn load_model(self: *const ModelAssetPath, alloc: std.mem.Allocator) !ms.Model {
        switch (self.*) {
            .Path => |p| {
                const asset_path = try en.engine().asset_manager.resolve_asset_path(alloc, p);
                defer alloc.free(asset_path);

                return try ms.Model.init_from_file_assimp(
                    alloc, 
                    pt.Path{ .Absolute = asset_path }, 
                    &en.engine().gfx
                );
            },
            .Plane => |d| {
                return try ms.Model.plane(alloc, d.slices, d.stacks, &en.engine().gfx);
            },
            .PlaneOnSphere => |d| {
                return try ms.Model.plane_on_sphere(
                    alloc, 
                    d.slices, 
                    d.stacks, 
                    d.plane_extent_radians, 
                    &en.engine().gfx
                );
            },
            .HeightMap => |h| {
                return try ms.Model.heightmap_plane_on_sphere(alloc, &h.height_map, .{
                    .slices = h.slices,
                    .stacks = h.stacks,
                    .plane_extent_radians = h.plane_extent_radians,
                    .heightmap_scale = h.height_map_scale,
                }, &en.engine().gfx);
            },
            .Cone => |d| {
                return try ms.Model.cone(alloc, d.slices, &en.engine().gfx);
            },
            .Sphere => |s| {
                return try ms.Model.sphere(alloc, s.slices, s.stacks, &en.engine().gfx);
            },
            .Cube => {
                return try ms.Model.cube(alloc, &en.engine().gfx);
            },
        }
    }
};


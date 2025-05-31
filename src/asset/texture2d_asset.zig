const std = @import("std");
const eng = @import("../root.zig");
const im = eng.image;
const gf = eng.gfx;
const pt = eng.path;
const FileWatcher = @import("file_watcher.zig");

pub const Texture2dPath = union(enum) {
    Path: []const u8,
};

pub const Texture2dAsset = struct {
    const Self = @This();
    pub const BaseType = gf.Texture2D;

    arena: std.heap.ArenaAllocator,

    path: Texture2dPath,

    loaded_texture: ?struct {
        watcher: ?FileWatcher = null,
        texture: gf.Texture2D
    } = null,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, path: Texture2dPath) !Self {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var owned_path = path;
        switch (owned_path) {
            .Path => |p| { 
                owned_path = .{ 
                    .Path = try arena.allocator().dupe(u8, p)
                };
            },
        }

        return .{
            .arena = arena,
            .path = owned_path,
        };
    }

    pub fn unload(self: *Self) void {
        if (self.loaded_texture) |*t| {
            if (t.watcher) |*w| {
                w.deinit();
            }
            t.texture.deinit();
        }
    }

    pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
        const texture = try load_texture(alloc, &self.path);
        errdefer texture.deinit();

        var watcher = switch (self.path) {
            .Path => |p| blk: {
                const asset_path = try eng.get().asset_manager.resolve_asset_path(alloc, p);
                defer alloc.free(asset_path);

                break :blk try FileWatcher.init(alloc, asset_path, 500);
            },
        };
        errdefer if (watcher) |*w| { w.deinit(); };

        self.loaded_texture = .{
            .texture = texture,
            .watcher = watcher,
        };
    }

    pub fn reload(self: *Self, alloc: std.mem.Allocator) !void {
        const loaded_texture = &(self.loaded_texture orelse return);

        const new_texture = try load_texture(alloc, &self.path);
        errdefer new_texture.deinit();

        loaded_texture.texture.deinit();
        loaded_texture.texture = new_texture;
    }

    pub fn file_watcher(self: *Self) ?*FileWatcher {
        const loaded_texture = &(self.loaded_texture orelse return null);
        return &(loaded_texture.watcher orelse return null);
    }

    pub fn loaded_asset(self: *Self) ?*BaseType {
        const loaded_texture = &(self.loaded_texture orelse return null);
        return &loaded_texture.texture;
    }

    pub fn load_texture(alloc: std.mem.Allocator, path: *const Texture2dPath) !gf.Texture2D {
        switch (path.*) {
            .Path => |p| {
                const asset_path = try eng.path.Path.init(alloc, .{ .Asset = p });
                defer asset_path.deinit();

                var image = im.ImageLoader.load_from_file(
                    alloc, 
                    asset_path,
                    .{}
                ) catch |err| {
                    std.log.err("Failed to load texture '{s}': {}", .{ p, err });
                    return error.TextureLoadFailed;
                };
                defer image.deinit();

                const format = blk: {
                    if (image.is_hdr) {
                        switch (image.num_components) {
                            1 => break :blk gf.TextureFormat.R32_Float,
                            2 => break :blk gf.TextureFormat.Rg32_Float,
                            4 => break :blk gf.TextureFormat.Rgba32_Float,
                            else => return error.UnsupportedTextureFormat,
                        }
                    } else {
                        switch (image.num_components) {
                            4 => break :blk gf.TextureFormat.Rgba8_Unorm,
                            else => return error.UnsupportedTextureFormat,
                        }
                    }
                };

                return gf.Texture2D.init(
                    .{
                        .height = image.height,
                        .width = image.width,
                        .format = format,
                        .array_length = 1,
                        .mip_levels = 1,
                    },
                    .{ .ShaderResource = true, },
                    .{},
                    image.data,
                    &eng.get().gfx
                );
            },
        }
    }
};

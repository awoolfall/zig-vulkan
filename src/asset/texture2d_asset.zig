const std = @import("std");
const eng = @import("../root.zig");
const im = eng.image;
const gf = eng.gfx;
const pt = eng.path;
const FileWatcher = @import("file_watcher.zig");

pub const ImagePath = union(enum) {
    Path: []const u8,
};

pub const ImageAsset = struct {
    const Self = @This();
    pub const BaseType = gf.Image.Ref;

    arena: std.heap.ArenaAllocator,

    path: ImagePath,

    loaded: ?struct {
        watcher: ?FileWatcher = null,
        image: gf.Image.Ref,
    } = null,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, path: ImagePath) !Self {
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
        if (self.loaded) |*t| {
            if (t.watcher) |*w| {
                w.deinit();
            }
            t.image.deinit();
        }
    }

    pub fn load(self: *Self, alloc: std.mem.Allocator) !void {
        const image = try load_image(alloc, &self.path);
        errdefer image.deinit();

        var watcher = switch (self.path) {
            .Path => |p| blk: {
                const asset_path = try eng.get().asset_manager.resolve_asset_path(alloc, p);
                defer alloc.free(asset_path);

                break :blk try FileWatcher.init(alloc, asset_path, 500);
            },
        };
        errdefer if (watcher) |*w| { w.deinit(); };

        self.loaded = .{
            .image = image,
            .watcher = watcher,
        };
    }

    pub fn reload(self: *Self, alloc: std.mem.Allocator) !void {
        const loaded = &(self.loaded orelse return);

        const new_image = try load_image(alloc, &self.path);
        errdefer new_image.deinit();

        loaded.image.deinit();
        loaded.image = new_image;
    }

    pub fn file_watcher(self: *Self) ?*FileWatcher {
        const loaded = &(self.loaded orelse return null);
        return &(loaded.watcher orelse return null);
    }

    pub fn loaded_asset(self: *Self) ?*BaseType {
        const loaded = &(self.loaded orelse return null);
        return &loaded.image;
    }

    pub fn load_image(alloc: std.mem.Allocator, path: *const ImagePath) !gf.Image.Ref {
        switch (path.*) {
            .Path => |p| {
                const asset_path = try eng.path.Path.init(alloc, .{ .Asset = p });
                defer asset_path.deinit();

                var image = im.ImageLoader.load_from_file(
                    alloc, 
                    asset_path,
                    .{}
                ) catch |err| {
                    std.log.err("Failed to load image '{s}': {}", .{ p, err });
                    return error.ImageLoadFailed;
                };
                defer image.deinit();

                const format = blk: {
                    if (image.is_hdr) {
                        switch (image.num_components) {
                            1 => break :blk gf.ImageFormat.R32_Float,
                            2 => break :blk gf.ImageFormat.Rg32_Float,
                            4 => break :blk gf.ImageFormat.Rgba32_Float,
                            else => return error.UnsupportedImageFormat,
                        }
                    } else {
                        switch (image.num_components) {
                            4 => break :blk gf.ImageFormat.Rgba8_Unorm,
                            else => return error.UnsupportedImageFormat,
                        }
                    }
                };

                return gf.Image.init(
                    .{
                        .height = image.height,
                        .width = image.width,
                        .depth = 1,
                        .format = format,
                        .array_length = 1,
                        .mip_levels = 1,

                        .usage_flags = .{ .ShaderResource = true, },
                        .access_flags = .{},
                    },
                    image.data,
                );
            },
        }
    }
};

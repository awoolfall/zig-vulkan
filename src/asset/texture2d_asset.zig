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
    pub const Path = ImagePath;

    arena: std.heap.ArenaAllocator,

    path: ImagePath,

    loaded: ?struct {
        watcher: ?FileWatcher = null,
        image: gf.Image.Ref,
    } = null,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, path: Self.Path) !Self {
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

        gf.GfxState.get().flush();
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

                const pp = try asset_path.resolve_path(alloc);
                defer alloc.free(pp);

                var dir: ?std.fs.Dir = std.fs.openDirAbsolute(pp, .{ .iterate = true }) catch null;
                defer if (dir) |*d| { d.close(); };

                if (dir) |texture_array_dir| {
                    return try Self.load_image_array(alloc, texture_array_dir);
                } else {
                    return try Self.load_single_image(alloc, asset_path);
                }
            },
        }
    }

    fn determine_image_format(image: *const im.Image) !gf.ImageFormat {
        return blk: {
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
    }

    fn load_single_image(alloc: std.mem.Allocator, asset_path: eng.path.Path) !gf.Image.Ref {
        const path_string = try asset_path.resolve_path(alloc);
        defer alloc.free(path_string);

        var image = im.ImageLoader.load_from_file(
            alloc, 
            path_string,
            .{}
        ) catch |err| {
            std.log.err("Failed to load image: {}", .{err});
            return error.ImageLoadFailed;
        };
        defer image.deinit();

        return gf.Image.init(
            .{
                .height = image.height,
                .width = image.width,
                .depth = 1,
                .format = try determine_image_format(&image),
                .array_length = 1,
                .mip_levels = 1,

                .usage_flags = .{ .ShaderResource = true, },
                .access_flags = .{},
                .dst_layout = .ShaderReadOnlyOptimal,
            },
            image.data,
        );
    }

    /// Creates an array image from a directory of image files named as just the layer they take
    /// i.e an asset_dir containing 3 files: '0.png, 1.png, 2.png' produces image array with 3 layers.
    fn load_image_array(alloc: std.mem.Allocator, asset_dir: std.fs.Dir) !gf.Image.Ref {
        var images_list = std.ArrayList(?im.Image).init(alloc);
        defer images_list.deinit();
        defer for (images_list.items) |*maybe_image| {
            if (maybe_image.*) |*image| {
                image.deinit();
            }
        };

        var dir_iter = asset_dir.iterate();
        while (try dir_iter.next()) |item| {
            if (item.kind == .file) {
                const filename_stem = std.fs.path.stem(item.name);
                const filename_int = std.fmt.parseUnsigned(u32, filename_stem, 10) catch |err| {
                    std.log.warn("Unable to parse image array filename stem to integer '{s}': {}", .{item.name, err});
                    continue;
                };

                if (filename_int > 16) {
                    std.log.warn("Image array filename integer was larger than the maximum, 16. '{s}'", .{item.name});
                    continue;
                }

                if (images_list.items.len <= filename_int) {
                    try images_list.appendNTimes(null, (filename_int + 1) - images_list.items.len);
                }

                const absolute_file_path = try asset_dir.realpathAlloc(alloc, item.name);
                defer alloc.free(absolute_file_path);

                if (images_list.items[filename_int] != null) {
                    std.log.err("Failed loading image array as image already exists at index '{s}'", .{absolute_file_path});
                    return error.ImageAlreadyExistsAtIndex;
                }

                var image = im.ImageLoader.load_from_file(
                    alloc, 
                    absolute_file_path,
                    .{}
                ) catch |err| {
                    std.log.err("Failed to load image: {}", .{err});
                    return error.ImageLoadFailed;
                };
                errdefer image.deinit();

                images_list.items[filename_int] = image;
            }
        }

        const first_image: *im.Image = for (images_list.items) |*maybe_image| {
            if (maybe_image.*) |*image| {
                break image;
            }
        } else return error.NoImagesExistInDirectory;

        for (images_list.items) |*maybe_image| {
            if (maybe_image.*) |*image| {
                const image_dimensions_match =
                    (image.height == first_image.height) and
                    (image.width == first_image.width);
                const image_formats_match =
                    (image.num_components == first_image.num_components) and
                    (image.bytes_per_component == first_image.bytes_per_component) and
                    (image.is_hdr == first_image.is_hdr);

                if (!image_dimensions_match) {
                    return error.MismatchingImageDimensions;
                }
                if (!image_formats_match) {
                    return error.MismatchingImageFormats;
                }
            }
        }

        const staging_buffer_image_byte_length =
            first_image.width *
            first_image.height *
            first_image.num_components *
            first_image.bytes_per_component;
        const staging_buffer_byte_length = staging_buffer_image_byte_length * images_list.items.len;

        const staging_buffer = try gf.Buffer.init(
            @intCast(staging_buffer_byte_length),
            .{ .TransferSrc = true, },
            .{ .CpuWrite = true, },
        );
        defer staging_buffer.deinit();

        {
            const mapped_staging_buffer = try (try staging_buffer.get()).map(.{ .write = .EveryFrame, });
            defer mapped_staging_buffer.unmap();

            const data = mapped_staging_buffer.data_array(u8, staging_buffer_byte_length);
            for (images_list.items, 0..) |*maybe_image, idx| {
                const start = staging_buffer_image_byte_length * idx;
                const end = start + staging_buffer_image_byte_length;

                if (maybe_image.*) |*image| {
                    @memcpy(data[start..end], image.data);
                } else {
                    @memset(data[start..end], 0);
                }
            }
        }

        const image = try gf.Image.init(
            .{
                .height = first_image.height,
                .width = first_image.width,
                .depth = 1,
                .format = try determine_image_format(first_image),
                .array_length = @intCast(images_list.items.len),
                .mip_levels = 1,

                .usage_flags = .{ .TransferDst = true, .ShaderResource = true, },
                .access_flags = .{},
                .dst_layout = .TransferDstOptimal,
            },
            null
        );
        errdefer image.deinit();

        const cmd_pool = try gf.CommandPool.init(.{ .queue_family = .Graphics, });
        defer cmd_pool.deinit();

        var cmd = try (try cmd_pool.get()).allocate_command_buffer(.{});
        defer cmd.deinit();

        {
            try cmd.cmd_begin(.{ .one_time_submit = true, });

            cmd.cmd_copy_buffer_to_image(.{
                .buffer = staging_buffer,
                .image = image,
                .copy_regions = &.{
                    gf.CommandBuffer.CopyRegionInfo {
                        .base_array_layer = 0,
                        .layer_count = @intCast(images_list.items.len),
                        .image_extent = .{ first_image.width, first_image.height, 1 },
                    },
                },
            });

            try cmd.cmd_end();
        }

        try gf.GfxState.get().submit_command_buffer(gf.GfxState.SubmitInfo {
            .command_buffers = &.{ &cmd },
        });

        // TODO: better synchronisation
        gf.GfxState.get().flush();

        return image;
    }
};

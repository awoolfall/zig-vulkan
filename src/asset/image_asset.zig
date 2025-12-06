const std = @import("std");
const eng = @import("../root.zig");
const zstbi = @import("zstbi");
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
        is_image_array: bool,
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
        const is_image_array = switch (self.path) {
            .Path => |p| blk: {
                const asset_path = try eng.path.Path.init(alloc, .{ .Asset = p });
                defer asset_path.deinit();

                const pp = try asset_path.resolve_path(alloc);
                defer alloc.free(pp);

                var dir: ?std.fs.Dir = std.fs.openDirAbsolute(pp, .{ .iterate = true }) catch null;
                defer if (dir) |*d| { d.close(); };
                
                break :blk (dir != null);
            },
        };

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
            .is_image_array = is_image_array,
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

    pub const WriteImageOptions = struct {
        array_layer: usize = 0,
        mip_level: usize = 0,
    };

    pub fn write_image(self: *Self, options: WriteImageOptions, image_data: *im.Image) !void {
        const image_ref = self.loaded_asset() orelse return error.AssetIsNotLoaded;
        const image = image_ref.get() catch return error.FailedToGetImage;

        // Run checks
        const required_data_length = 
            image.info.width *
            image.info.height *
            image.info.depth *
            image.info.array_length *
            image.info.format.byte_width();
        if (image_data.data.len < required_data_length) {
            return error.DataIsNotRequiredLength;
        }

        if (options.array_layer >= image.info.array_length) {
            if (!self.loaded.?.is_image_array) {
                return error.NotAnImageArray;
            }
            if (options.array_layer > 128) {
                return error.LayerTooLarge;
            }
        }

        if (options.mip_level >= image.info.mip_levels) {
            return error.MipLevelTooLarge;
        }

        // Find file on disk
        const dir_string = std.fs.path.dirname(self.path.Path);
        const dir = try std.fs.openDirAbsolute(dir_string, .{ .iterate = self.loaded.?.is_image_array, });
        defer dir.close();

        const alloc = eng.get().general_allocator;

        const filename_z = 
            if (!self.loaded.?.is_image_array) blk: {
                const file_string = std.fs.path.basename(self.path.Path);
                _ = try dir.statFile(file_string);

                break :blk alloc.dupeZ(u8, file_string);
            }
            else blk: {
                var maybe_extension: ?[]u8 = null;

                var iter = dir.iterate();
                while (true) {
                    const entry = iter.next() catch break orelse break;
                    if (entry.kind == .file) {
                        if (maybe_extension == null) {
                            maybe_extension = std.fs.path.extension(entry.name);
                        }

                        const file_stem = std.fs.path.stem(entry.name);
                        const file_number = std.fmt.parseUnsigned(u32, file_stem, 10) catch continue;
                        if (file_number == options.array_layer) {
                            break :blk try alloc.dupeZ(u8, entry.name);
                        }
                    }
                } else {
                    const extension = maybe_extension orelse return error.CouldNotDetermineAppropriateExtension;
                    break :blk try std.fmt.allocPrintZ(alloc, "{}{s}", .{options.array_layer, extension});
                }
            };
        defer alloc.free(filename_z);

        const extension = std.fs.path.extension(filename_z);

        if (std.mem.eql(u8, extension, ".f32")) {
            const file = try dir.createFile(filename_z, .{});
            defer file.close();

            std.log.info("Writing image data to {s}//{s}", .{dir_string, filename_z});
            try file.writeAll(image_data.data);
        } else if (std.mem.eql(u8, extension, ".png")) {
            const zstbi_image = try image_data.to_zstbi();
            defer zstbi_image.deinit();

            const cwd = std.fs.cwd();
            try dir.setAsCwd();
            defer cwd.setAsCwd() catch unreachable;

            std.log.info("Writing image data to {s}//{s}", .{dir_string, filename_z});
            try zstbi_image.writeToFile(filename_z, .png);
        } else {
            return error.UnsupportedExtension;
        }
    }
    
    fn load_image(alloc: std.mem.Allocator, path: *const ImagePath) !gf.Image.Ref {
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
        var image = try Self.load_single_image_cpu(alloc, asset_path);
        defer image.deinit();

        // @TODO make mip generation optional
        // generate mips down to 32 by 32
        const mip_levels: u32 = @max(std.math.log2(@min(image.width, image.height)), 5) - 4;

        return gf.Image.init(
            .{
                .height = image.height,
                .width = image.width,
                .depth = 1,
                .format = try determine_image_format(&image),
                .array_length = 1,
                .mip_levels = mip_levels,

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
        const MAX_IMAGES = 16;
        var images_buffer: [MAX_IMAGES]?im.Image = [_]?im.Image{ null } ** MAX_IMAGES;
        defer for (&images_buffer) |*maybe_image| {
            if (maybe_image.*) |*image| {
                image.deinit();
            }
        };

        var lowest_image_idx: usize = std.math.maxInt(usize);
        var highest_image_idx: usize = std.math.minInt(usize);

        var dir_iter = asset_dir.iterate();
        while (try dir_iter.next()) |item| {
            if (item.kind == .file) {
                const filename_stem = std.fs.path.stem(item.name);
                const filename_int = std.fmt.parseUnsigned(u32, filename_stem, 10) catch |err| {
                    std.log.warn("Unable to parse image array filename stem to integer '{s}': {}", .{item.name, err});
                    continue;
                };

                if (filename_int > MAX_IMAGES) {
                    std.log.warn("Image array filename integer was larger than the maximum, 16. '{s}'", .{item.name});
                    continue;
                }

                const absolute_file_path = try asset_dir.realpathAlloc(alloc, item.name);
                defer alloc.free(absolute_file_path);

                if (images_buffer[filename_int] != null) {
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

                lowest_image_idx = @min(lowest_image_idx, filename_int);
                highest_image_idx = @max(highest_image_idx, filename_int);

                images_buffer[filename_int] = image;
            }
        }

        const first_image: *im.Image =
            if (lowest_image_idx < MAX_IMAGES)
                &(images_buffer[lowest_image_idx] orelse return error.NoImageInLowestIdx)
            else return error.NoImagesExistInDirectory;

        const array_count = highest_image_idx + 1;

        for (&images_buffer) |*maybe_image| {
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
        const staging_buffer_byte_length = staging_buffer_image_byte_length * array_count;

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
            for (0..highest_image_idx) |idx| {
                const maybe_image = &images_buffer[idx];

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
                .array_length = @intCast(array_count),
                .mip_levels = 5,

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
                        .layer_count = @intCast(array_count),
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

    pub fn load_image_cpu(self: *const Self, alloc: std.mem.Allocator, array_layer: usize) !im.Image {
        switch (self.path) {
            .Path => |p| {
                const asset_path = try eng.path.Path.init(alloc, .{ .Asset = p });
                defer asset_path.deinit();

                const pp = try asset_path.resolve_path(alloc);
                defer alloc.free(pp);

                var dir: ?std.fs.Dir = std.fs.openDirAbsolute(pp, .{ .iterate = true }) catch null;
                defer if (dir) |*d| { d.close(); };

                if (dir) |texture_array_dir| {
                    return try Self.load_image_array_layer_cpu(alloc, texture_array_dir, array_layer);
                } else {
                    return try Self.load_single_image_cpu(alloc, asset_path);
                }
            },
        }
    }

    fn load_single_image_cpu(alloc: std.mem.Allocator, asset_path: eng.path.Path) !im.Image {
        const path_string = try asset_path.resolve_path(alloc);
        defer alloc.free(path_string);

        return im.ImageLoader.load_from_file(
            alloc, 
            path_string,
            .{}
        ) catch |err| {
            std.log.err("Failed to load image: {}", .{err});
            return error.ImageLoadFailed;
        };
    }

    fn load_image_array_layer_cpu(alloc: std.mem.Allocator, asset_dir: std.fs.Dir, array_layer: usize) !im.Image {
        var dir_iter = asset_dir.iterate();
        while (try dir_iter.next()) |item| {
            if (item.kind == .file) {
                const filename_stem = std.fs.path.stem(item.name);
                const filename_int = std.fmt.parseUnsigned(u32, filename_stem, 10) catch |err| {
                    std.log.warn("Unable to parse image array filename stem to integer '{s}': {}", .{item.name, err});
                    continue;
                };

                // continue until filename int is found
                if (filename_int != array_layer) {
                    continue;
                }

                const absolute_file_path = try asset_dir.realpathAlloc(alloc, item.name);
                defer alloc.free(absolute_file_path);

                return im.ImageLoader.load_from_file(
                    alloc, 
                    absolute_file_path,
                    .{}
                ) catch |err| {
                    std.log.err("Failed to load image: {}", .{err});
                    return error.ImageLoadFailed;
                };
            }
        } else {
            return error.ArrayLayerFileDoesNotExist;
        }
    }
};
